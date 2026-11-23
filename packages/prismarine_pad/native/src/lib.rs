//! The game pads of the host for an app. The gamepad subsystem of SDL3 reads
//! the pads on every desktop platform. It maps every known pad onto the
//! standard layout by button position. This crate picks the pad in use and
//! publishes its state to Dart once a frame. The app decides what to do with
//! that state.
//!
//! SDL runs on a thread of its own, `prismarine-pad`. It is started there and
//! every SDL call, such as pumping events or reading pads, happens there. SDL
//! requires this of the thread that started its events. Some of its drivers
//! keep state per thread, such as the run loop of the IOKit driver on macOS
//! and the window of raw input on Windows. A Dart isolate is not tied to one
//! OS thread. The readers therefore never call SDL. The thread polls every
//! few milliseconds and publishes a snapshot. The `prismarine_pad_*`
//! functions copy from it.
//!
//! The crate has no `unsafe`. The `sdl3` crate wraps SDL and the state goes
//! back to Dart by value.

use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use sdl3::event::Event;
use sdl3::gamepad::{Axis, Button, Gamepad};
use sdl3::joystick::JoystickId;

/// One reading with the connection state, the buttons in the bit order of
/// [`BUTTONS`], the sticks from −1 to 1 with y up, the triggers from 0 to 1
/// and the name of the pad.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PadReading {
    /// 1 while a pad is connected. With 0 the other fields are idle.
    pub connected: u8,
    /// 1 for a Microsoft Xbox pad, found by its USB vendor id.
    pub xbox: u8,
    /// 1 when SDL could not start and the machine has no pad support.
    pub unavailable: u8,
    pub reserved: u8,
    pub buttons: u32,
    pub left_x: f32,
    pub left_y: f32,
    pub right_x: f32,
    pub right_y: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
    /// The name of the pad in UTF-8, padded with NUL and cut at 63 bytes.
    pub name: [u8; 64],
}

impl PadReading {
    const fn none() -> Self {
        PadReading {
            connected: 0,
            xbox: 0,
            unavailable: 0,
            reserved: 0,
            buttons: 0,
            left_x: 0.0,
            left_y: 0.0,
            right_x: 0.0,
            right_y: 0.0,
            left_trigger: 0.0,
            right_trigger: 0.0,
            name: [0; 64],
        }
    }
}

/// One connected pad in the list of `prismarine_pad_device`. It has its SDL
/// GUID, which is the same for two pads of one model, its place among the
/// pads with that GUID in connection order and its name. `present` is 0 past
/// the end of the list.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PadDevice {
    pub present: u8,
    pub reserved: [u8; 3],
    /// The place of the pad among the connected pads with this
    /// [`PadDevice::uuid`], from 0.
    pub nth: u32,
    pub uuid: [u8; 16],
    pub name: [u8; 64],
}

/// The buttons in the bit order of [`PadReading::buttons`]. The face buttons
/// come first by position, A south, B east, X west and Y north. The
/// shoulders, Back, Start, the stick presses and the d-pad up, down, left and
/// right follow. SDL reports the buttons by position for every pad. The
/// Cross of a PlayStation pad and the B of a Switch pad, both at the bottom,
/// are A. Circle and the Switch A, both on the right, are B.
pub const BUTTONS: [Button; 14] = [
    Button::South,
    Button::East,
    Button::West,
    Button::North,
    Button::LeftShoulder,
    Button::RightShoulder,
    Button::Back,
    Button::Start,
    Button::LeftStick,
    Button::RightStick,
    Button::DPadUp,
    Button::DPadDown,
    Button::DPadLeft,
    Button::DPadRight,
];

/// The USB vendor id of Microsoft, for Xbox pads.
const MICROSOFT: u16 = 0x045e;

/// The interval at which the pad thread reads the pads, well inside a 60 fps
/// frame.
const POLL: Duration = Duration::from_millis(4);

/// A stick or trigger that moves this far, of 32767, makes its pad the pad
/// in use (Auto), as a button press does.
const MOVED: u16 = 16384;

/// One connected pad as the pad thread last read it.
#[derive(Clone, Copy)]
struct Snap {
    id: JoystickId,
    uuid: [u8; 16],
    nth: u32,
    reading: PadReading,
}

/// The state that the pad thread publishes.
struct Shared {
    /// True once the thread has tried to start SDL.
    started: bool,
    /// True when SDL could not start. No pad is read then.
    unavailable: bool,
    /// The connected pads, in connection order.
    pads: Vec<Snap>,
    /// The last pad on which a button, stick or trigger moved.
    active: Option<JoystickId>,
}

static SHARED: Mutex<Shared> = Mutex::new(Shared {
    started: false,
    unavailable: false,
    pads: Vec::new(),
    active: None,
});
static STARTED: Condvar = Condvar::new();
static SPAWN: std::sync::Once = std::sync::Once::new();

fn lock() -> MutexGuard<'static, Shared> {
    match SHARED.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Returns the published state. The first call starts the pad thread and
/// waits until SDL is up and has listed the pads already connected.
fn shared() -> MutexGuard<'static, Shared> {
    SPAWN.call_once(|| {
        let spawned = thread::Builder::new()
            .name("prismarine-pad".into())
            .spawn(run);
        if spawned.is_err() {
            let mut s = lock();
            s.started = true;
            s.unavailable = true;
        }
    });
    let mut s = lock();
    while !s.started {
        s = match STARTED.wait(s) {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
    }
    s
}

/// Sets the hints of SDL before it starts. SDL installs no signal handlers,
/// since the Dart VM and Flutter own SIGINT and SIGTERM. Pads are read while
/// the window is in the background too. There is no SDL window and the app
/// decides.
fn hints() {
    sdl3::hint::set("SDL_NO_SIGNAL_HANDLERS", "1");
    sdl3::hint::set("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
}

/// SDL with only its gamepad subsystem and the joystick and event subsystems
/// that it needs. It has no video.
struct Sdl {
    // Dropping it shuts the subsystem down.
    gamepads: sdl3::GamepadSubsystem,
    pump: sdl3::EventPump,
    #[cfg(test)]
    joysticks: sdl3::JoystickSubsystem,
    _sdl: sdl3::Sdl,
}

fn start() -> Result<Sdl, String> {
    hints();
    let sdl = sdl3::init().map_err(|e| e.to_string())?;
    let gamepads = sdl.gamepad().map_err(|e| e.to_string())?;
    #[cfg(test)]
    let joysticks = sdl.joystick().map_err(|e| e.to_string())?;
    let pump = sdl.event_pump().map_err(|e| e.to_string())?;
    Ok(Sdl {
        gamepads,
        pump,
        #[cfg(test)]
        joysticks,
        _sdl: sdl,
    })
}

/// Runs the pad thread. Starts SDL and then reads the pads every [`POLL`]
/// for the life of the process.
fn run() {
    let mut sdl = match start() {
        Ok(sdl) => sdl,
        Err(e) => {
            eprintln!("prismarine_pad: SDL could not start: {e}");
            let mut s = lock();
            s.started = true;
            s.unavailable = true;
            STARTED.notify_all();
            return;
        }
    };
    let mut open: Vec<(JoystickId, Gamepad)> = Vec::new();
    let mut active: Option<JoystickId> = None;
    #[cfg(test)]
    let mut keep: Vec<Box<dyn std::any::Any>> = Vec::new();
    // The pads connected before SDL started.
    if let Ok(ids) = sdl.gamepads.gamepads() {
        for id in ids {
            add(&sdl.gamepads, &mut open, id);
        }
    }
    loop {
        #[cfg(test)]
        for job in std::mem::take(&mut *tests::jobs()) {
            job(&sdl, &mut keep);
        }
        for ev in sdl.pump.poll_iter() {
            match ev {
                Event::GamepadAdded { which, .. } => add(&sdl.gamepads, &mut open, which),
                Event::GamepadRemoved { which, .. } => {
                    open.retain(|(id, _)| *id != which);
                    if active == Some(which) {
                        active = None;
                    }
                }
                Event::GamepadButtonDown { which, .. } => active = Some(which),
                Event::GamepadAxisMotion { which, value, .. } if value.unsigned_abs() > MOVED => {
                    active = Some(which)
                }
                _ => {}
            }
        }
        let pads = snapshot(&sdl.gamepads, &open);
        {
            let mut s = lock();
            s.pads = pads;
            s.active = active;
            if !s.started {
                s.started = true;
                STARTED.notify_all();
            }
        }
        thread::sleep(POLL);
    }
}

fn add(gamepads: &sdl3::GamepadSubsystem, open: &mut Vec<(JoystickId, Gamepad)>, id: JoystickId) {
    if open.iter().any(|(i, _)| *i == id) {
        return;
    }
    match gamepads.open(id) {
        Ok(pad) => open.push((id, pad)),
        Err(e) => eprintln!("prismarine_pad: could not open pad {}: {e}", id.raw()),
    }
}

/// Returns the reading of every open pad with its GUID and its place among
/// the pads of that GUID.
fn snapshot(gamepads: &sdl3::GamepadSubsystem, open: &[(JoystickId, Gamepad)]) -> Vec<Snap> {
    let mut out: Vec<Snap> = Vec::with_capacity(open.len());
    for (id, pad) in open {
        let uuid = gamepads.guid_for_id(*id).raw.data;
        let nth = out.iter().filter(|s| s.uuid == uuid).count() as u32;
        out.push(Snap {
            id: *id,
            uuid,
            nth,
            reading: reading(pad),
        });
    }
    out
}

/// Maps a stick axis of SDL from −32768…32767 to −1…1.
fn stick(v: i16) -> f32 {
    (f32::from(v) / 32767.0).clamp(-1.0, 1.0)
}

/// Maps a trigger axis of SDL from 0…32767 to 0…1.
fn trigger(v: i16) -> f32 {
    (f32::from(v) / 32767.0).clamp(0.0, 1.0)
}

fn reading(pad: &Gamepad) -> PadReading {
    let mut r = PadReading::none();
    r.connected = 1;
    r.xbox = u8::from(pad.vendor_id() == Some(MICROSOFT));
    for (i, b) in BUTTONS.iter().enumerate() {
        if pad.button(*b) {
            r.buttons |= 1 << i;
        }
    }
    // The y axes of SDL point down. The readings point up.
    r.left_x = stick(pad.axis(Axis::LeftX));
    r.left_y = -stick(pad.axis(Axis::LeftY));
    r.right_x = stick(pad.axis(Axis::RightX));
    r.right_y = -stick(pad.axis(Axis::RightY));
    r.left_trigger = trigger(pad.axis(Axis::TriggerLeft));
    r.right_trigger = trigger(pad.axis(Axis::TriggerRight));
    put_name(&mut r.name, &pad.name().unwrap_or_default());
    r
}

fn put_name(dst: &mut [u8; 64], name: &str) {
    let b = name.as_bytes();
    let n = b.len().min(dst.len() - 1);
    dst[..n].copy_from_slice(&b[..n]);
}

/// Returns the `i`-th connected pad. The first call starts SDL.
#[no_mangle]
pub extern "C" fn prismarine_pad_device(i: u32) -> PadDevice {
    let none = PadDevice {
        present: 0,
        reserved: [0; 3],
        nth: 0,
        uuid: [0; 16],
        name: [0; 64],
    };
    let s = shared();
    match s.pads.get(i as usize) {
        Some(p) => PadDevice {
            present: 1,
            nth: p.nth,
            uuid: p.uuid,
            name: p.reading.name,
            ..none
        },
        None => none,
    }
}

/// Returns the pad in use now (Auto). It is the last pad on which a button,
/// stick or trigger moved, else the first connected pad. The first call
/// starts SDL.
#[no_mangle]
pub extern "C" fn prismarine_pad_read() -> PadReading {
    read(Choice::Any)
}

/// Returns the chosen pad, the `nth` connected pad whose GUID is `uuid_hi` ‖
/// `uuid_lo` in big-endian halves. It reads as not connected while it is
/// missing. Every other pad is ignored.
#[no_mangle]
pub extern "C" fn prismarine_pad_read_chosen(uuid_hi: u64, uuid_lo: u64, nth: u32) -> PadReading {
    let mut uuid = [0u8; 16];
    uuid[..8].copy_from_slice(&uuid_hi.to_be_bytes());
    uuid[8..].copy_from_slice(&uuid_lo.to_be_bytes());
    read(Choice::Pad { uuid, nth })
}

/// The pad that the player plays with.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Choice {
    /// The last pad on which a button or stick moved, else the first (Auto).
    Any,
    /// The `nth` connected pad with this GUID. It reads as none while it is
    /// missing.
    Pad { uuid: [u8; 16], nth: u32 },
}

fn read(choice: Choice) -> PadReading {
    let s = shared();
    if s.unavailable {
        let mut r = PadReading::none();
        r.unavailable = 1;
        return r;
    }
    let pad = match choice {
        Choice::Any => s
            .active
            .and_then(|id| s.pads.iter().find(|p| p.id == id))
            .or_else(|| s.pads.first()),
        Choice::Pad { uuid, nth } => s.pads.iter().find(|p| p.uuid == uuid && p.nth == nth),
    };
    pad.map_or(PadReading::none(), |p| p.reading)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sdl3::joystick::{JoystickType, VirtualJoystickDescription};
    use std::time::Instant;

    type Job = Box<dyn FnOnce(&Sdl, &mut Vec<Box<dyn std::any::Any>>) + Send>;
    static JOBS: Mutex<Vec<Job>> = Mutex::new(Vec::new());

    /// The jobs for the pad thread. SDL is only called on that thread.
    pub(super) fn jobs() -> MutexGuard<'static, Vec<Job>> {
        match JOBS.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Runs `f` on the pad thread and waits for it.
    fn on_pad_thread<T: Send + 'static>(
        f: impl FnOnce(&Sdl, &mut Vec<Box<dyn std::any::Any>>) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        jobs().push(Box::new(move |sdl, keep| {
            let _ = tx.send(f(sdl, keep));
        }));
        rx.recv_timeout(Duration::from_secs(5))
            .expect("the pad thread runs jobs")
    }

    /// Waits until `ok` holds for the published state. The pad thread polls
    /// every few milliseconds. `what` describes the state in the message of a
    /// timeout.
    fn eventually(what: &str, ok: impl Fn() -> bool) {
        let t = Instant::now();
        while !ok() {
            assert!(t.elapsed() < Duration::from_secs(5), "timed out: {what}");
            thread::sleep(Duration::from_millis(5));
        }
    }

    /// Returns the connected pads as an app lists them.
    fn devices() -> Vec<PadDevice> {
        let mut out = Vec::new();
        for i in 0..64 {
            let d = prismarine_pad_device(i);
            if d.present == 0 {
                break;
            }
            out.push(d);
        }
        out
    }

    fn name_of(n: &[u8; 64]) -> String {
        let end = n.iter().position(|b| *b == 0).unwrap_or(64);
        String::from_utf8_lossy(&n[..end]).into_owned()
    }

    /// The real SDL starts with these hints on this machine. A test with
    /// fakes would not see a hint that makes SDL refuse to start.
    #[test]
    fn sdl_starts_with_our_settings() {
        let r = prismarine_pad_read();
        assert_eq!(r.unavailable, 0, "SDL did not start (see stderr)");
    }

    /// A virtual pad attached to the real SDL is listed by name, GUID and
    /// place. Its buttons are read by position, its sticks with y up and its
    /// triggers from 0 to 1. Auto follows the pad last used. A chosen pad
    /// reads only itself. The checks are one test, which keeps the pads of
    /// other tests from coming and going meanwhile.
    #[test]
    fn virtual_pads_through_sdl() {
        assert_eq!(prismarine_pad_read().unavailable, 0);
        // Every button and axis of the SDL gamepad, in the order of SDL. The
        // raw index of each on the virtual pad is then its SDL code.
        let all = [
            Button::South,
            Button::East,
            Button::West,
            Button::North,
            Button::Back,
            Button::Guide,
            Button::Start,
            Button::LeftStick,
            Button::RightStick,
            Button::LeftShoulder,
            Button::RightShoulder,
            Button::DPadUp,
            Button::DPadDown,
            Button::DPadLeft,
            Button::DPadRight,
        ];
        let axes = [
            Axis::LeftX,
            Axis::LeftY,
            Axis::RightX,
            Axis::RightY,
            Axis::TriggerLeft,
            Axis::TriggerRight,
        ];
        let attach = move |name: &'static str| {
            on_pad_thread(move |sdl, keep| {
                let desc = VirtualJoystickDescription::new()
                    .name(name)
                    .joystick_type(JoystickType::Gamepad)
                    .with_buttons(all)
                    .with_axes(axes);
                let conn = sdl
                    .joysticks
                    .attach_virtual_joystick(desc)
                    .expect("virtual pad");
                let id = conn.id();
                let joy = sdl.joysticks.open(id).expect("open virtual pad");
                keep.push(Box::new(conn));
                keep.push(Box::new(joy));
                id.raw()
            })
        };
        let set = |id: u32, buttons: &'static [Button], axes: &'static [(Axis, i16)]| {
            on_pad_thread(move |sdl, _| {
                let joy = sdl.joysticks.open(JoystickId::new(id)).expect("open");
                for b in all {
                    joy.set_virtual_button(b.to_ll().0 as u32, buttons.contains(&b))
                        .expect("button");
                }
                for (a, v) in axes {
                    joy.set_virtual_axis(a.to_ll().0 as u32, *v).expect("axis");
                }
            })
        };
        let listed = |name: &str| -> Option<PadDevice> {
            devices().into_iter().find(|d| name_of(&d.name) == name)
        };
        let chosen = |d: PadDevice| {
            let hi = u64::from_be_bytes(d.uuid[..8].try_into().unwrap());
            let lo = u64::from_be_bytes(d.uuid[8..].try_into().unwrap());
            prismarine_pad_read_chosen(hi, lo, d.nth)
        };

        let a = attach("prismarine test pad");
        eventually("the virtual pad is listed", || {
            listed("prismarine test pad").is_some()
        });
        let da = listed("prismarine test pad").unwrap();
        assert_eq!(chosen(da).connected, 1);
        assert_eq!(chosen(da).buttons, 0);

        // South is A at bit 0, East is B, West is X and North is Y. The
        // shoulders, Back, Start, the stick presses and the d-pad follow in
        // the order of BUTTONS.
        set(
            a,
            &[Button::South, Button::RightShoulder, Button::DPadLeft],
            &[
                (Axis::LeftX, 32767),
                (Axis::LeftY, -32768),
                (Axis::RightY, 16384),
                (Axis::TriggerLeft, 32767),
            ],
        );
        eventually("the presses arrive", || chosen(da).buttons != 0);
        let r = chosen(da);
        assert_eq!(r.buttons, 1 << 0 | 1 << 5 | 1 << 12, "A, RB and d-pad left");
        assert_eq!(r.left_x, 1.0);
        assert_eq!(r.left_y, 1.0, "stick up reads +1");
        assert!(
            (r.right_y + 0.5).abs() < 1e-3,
            "stick half down reads −0.5: {}",
            r.right_y
        );
        assert_eq!(r.left_trigger, 1.0);
        assert_eq!(r.right_trigger, 0.0);
        assert_eq!(name_of(&r.name), "prismarine test pad");
        set(
            a,
            &[
                Button::East,
                Button::West,
                Button::North,
                Button::Back,
                Button::Start,
            ],
            &[],
        );
        eventually("B X Y Back Start", || chosen(da).buttons == 0b1100_1110);
        set(
            a,
            &[
                Button::LeftShoulder,
                Button::LeftStick,
                Button::RightStick,
                Button::DPadUp,
                Button::DPadDown,
                Button::DPadRight,
            ],
            &[],
        );
        eventually("LB L3 R3 up down right", || {
            chosen(da).buttons == 1 << 4 | 1 << 8 | 1 << 9 | 1 << 10 | 1 << 11 | 1 << 13
        });
        // Guide is not in BUTTONS.
        set(
            a,
            &[Button::Guide],
            &[
                (Axis::LeftX, 0),
                (Axis::LeftY, 0),
                (Axis::RightY, 0),
                (Axis::TriggerLeft, 0),
            ],
        );
        eventually("nothing held", || {
            chosen(da).buttons == 0 && chosen(da).left_x == 0.0
        });

        // A second pad of the same model has the same GUID and the next
        // place.
        let b = attach("prismarine test pad");
        eventually("two test pads", || {
            devices().iter().filter(|d| d.uuid == da.uuid).count() == 2
        });
        let db = devices()
            .into_iter()
            .find(|d| d.uuid == da.uuid && d.nth == 1)
            .unwrap();
        // Auto follows the pad last pressed. A chosen pad reads only itself.
        set(b, &[Button::North], &[]);
        eventually("Auto reads the second pad", || {
            prismarine_pad_read().buttons == 1 << 3
        });
        assert_eq!(chosen(da).buttons, 0);
        assert_eq!(chosen(db).buttons, 1 << 3);
        set(b, &[], &[]);
        set(a, &[Button::South], &[]);
        eventually("Auto back on the first pad", || {
            prismarine_pad_read().buttons == 1
        });
        assert_eq!(chosen(db).buttons, 0);

        // An unplugged pad is no longer listed. The chosen pad reads as none.
        on_pad_thread(move |sdl, keep| {
            keep.clear();
            let _ = sdl;
        });
        eventually("both gone", || listed("prismarine test pad").is_none());
        assert_eq!(chosen(da).connected, 0);
        let _ = b;
    }

    #[test]
    fn reading_is_c_sized() {
        assert_eq!(std::mem::size_of::<PadReading>(), 4 + 4 + 6 * 4 + 64);
    }

    #[test]
    fn device_is_c_sized() {
        assert_eq!(std::mem::size_of::<PadDevice>(), 4 + 4 + 16 + 64);
    }

    #[test]
    fn no_chosen_pad_reads_as_none() {
        let r = prismarine_pad_read_chosen(0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210, 7);
        assert_eq!(r.connected, 0);
        assert_eq!(r.buttons, 0);
        // The list ends with a non-present entry.
        assert_eq!(prismarine_pad_device(1000).present, 0);
    }

    #[test]
    fn axis_scaling() {
        assert_eq!(stick(32767), 1.0);
        assert_eq!(stick(-32768), -1.0);
        assert_eq!(stick(0), 0.0);
        assert_eq!(trigger(32767), 1.0);
        assert_eq!(trigger(0), 0.0);
        assert_eq!(trigger(-5), 0.0);
    }
}
