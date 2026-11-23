//! The host's game pads for an app. SDL3's gamepad subsystem
//! reads the pads on every desktop platform (on macOS through its HIDAPI
//! drivers for PlayStation, Xbox and Switch pads plus Apple's GameController
//! framework; Windows.Gaming.Input, XInput and raw input on Windows; evdev on
//! Linux) and maps every known pad onto the standard layout by button position.
//! This crate picks the one the player uses and hands its state to Dart once a
//! frame. The app decides what a game does with that state.
//!
//! SDL lives on a thread of its own (`prismarine-pad`): it is started there, and
//! every SDL call (pumping events, reading pads) happens there, as SDL asks
//! of the thread that started its events. Some of its drivers keep state per
//! thread (the IOKit driver's run loop on macOS, raw input's window on
//! Windows), and a Dart isolate is not tied to one OS thread, so the readers
//! never call SDL: the thread polls every few milliseconds and publishes a
//! snapshot, and the `prismarine_pad_*` functions copy from it.
//!
//! No `unsafe` here: the `sdl3` crate wraps SDL, and the state goes back to
//! Dart by value.

use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use sdl3::event::Event;
use sdl3::gamepad::{Axis, Button, Gamepad};
use sdl3::joystick::JoystickId;

/// One reading: whether a pad is connected, its buttons (the bit order of
/// [`BUTTONS`]), its sticks (−1…1, y up) and triggers (0…1), and its name.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PadReading {
    /// 1 while a pad is connected; 0 when there is none (the rest is idle).
    pub connected: u8,
    /// 1 for a Microsoft (Xbox) pad, by its USB vendor id.
    pub xbox: u8,
    /// 1 when SDL could not start (no pad support on this machine).
    pub unavailable: u8,
    pub reserved: u8,
    pub buttons: u32,
    pub left_x: f32,
    pub left_y: f32,
    pub right_x: f32,
    pub right_y: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
    /// The pad's name, UTF-8, NUL-padded (cut at 63 bytes).
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

/// One connected pad in the list (`prismarine_pad_device`): its SDL GUID (the
/// same for two pads of one model), which of the pads with that GUID it is
/// (in connection order), and its name. `present` 0 past the end.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PadDevice {
    pub present: u8,
    pub reserved: [u8; 3],
    /// The n-th connected pad with this [`PadDevice::uuid`] (0-based).
    pub nth: u32,
    pub uuid: [u8; 16],
    pub name: [u8; 64],
}

/// The buttons in [`PadReading::buttons`]' bit order: the face buttons by
/// position (A south, B east, X west, Y north), the shoulders, Back, Start,
/// the stick presses, then the d-pad up, down, left, right. SDL names the
/// buttons by position for every pad, so a PlayStation pad's Cross and a
/// Switch pad's B (both at the bottom) are the game's A, Circle and the
/// Switch A (right) its B, and so on.
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

/// The Xbox pads' USB vendor (Microsoft).
const MICROSOFT: u16 = 0x045e;

/// How often the pad thread reads the pads: well inside a 60 fps frame.
const POLL: Duration = Duration::from_millis(4);

/// A stick or trigger moved this far (of 32767) makes its pad the one in use
/// (Auto), as a button press does.
const MOVED: u16 = 16384;

/// One connected pad as the pad thread last read it.
#[derive(Clone, Copy)]
struct Snap {
    id: JoystickId,
    uuid: [u8; 16],
    nth: u32,
    reading: PadReading,
}

/// What the pad thread publishes.
struct Shared {
    /// The thread has started SDL (or failed to).
    started: bool,
    /// SDL could not start: pads are never read.
    unavailable: bool,
    /// The connected pads, in connection order.
    pads: Vec<Snap>,
    /// The last pad a button, stick or trigger moved on.
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

/// The published state, starting the pad thread on the first call and
/// waiting until SDL is up and has listed the pads already connected.
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

/// SDL's settings for us, before it starts: no signal handlers (the Dart
/// VM and Flutter own SIGINT/SIGTERM); pads read while the window is in the
/// background as well (there is no SDL window: the player decides).
fn hints() {
    sdl3::hint::set("SDL_NO_SIGNAL_HANDLERS", "1");
    sdl3::hint::set("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
}

/// SDL with only its gamepad subsystem (and the joystick and event
/// subsystems it needs); no video.
struct Sdl {
    // Kept alive: dropping it shuts the subsystem down.
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

/// The pad thread: starts SDL, then reads the pads every [`POLL`] for the
/// life of the process.
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

/// Every open pad's reading, with its GUID and its place among the pads of
/// that GUID.
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

/// A stick axis (SDL: −32768…32767) as −1…1.
fn stick(v: i16) -> f32 {
    (f32::from(v) / 32767.0).clamp(-1.0, 1.0)
}

/// A trigger axis (SDL: 0…32767) as 0…1.
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
    // SDL's y axes point down; ours up.
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

/// The `i`-th connected pad (starts SDL on the first call).
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

/// The pad in use now (Auto): the last one a button, stick or trigger moved
/// on, else the first connected one. Starts SDL on the first call.
#[no_mangle]
pub extern "C" fn prismarine_pad_read() -> PadReading {
    read(Choice::Any)
}

/// The chosen pad: the `nth` connected pad whose GUID is `uuid_hi` ‖
/// `uuid_lo` (big-endian halves); not connected while it isn't there, and
/// every other pad is ignored.
#[no_mangle]
pub extern "C" fn prismarine_pad_read_chosen(uuid_hi: u64, uuid_lo: u64, nth: u32) -> PadReading {
    let mut uuid = [0u8; 16];
    uuid[..8].copy_from_slice(&uuid_hi.to_be_bytes());
    uuid[8..].copy_from_slice(&uuid_lo.to_be_bytes());
    read(Choice::Pad { uuid, nth })
}

/// Which pad the player plays with.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Choice {
    /// The last one a button or stick moved on, else the first (Auto).
    Any,
    /// The `nth` connected pad with this GUID; none while it isn't there.
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

    /// Work for the pad thread (SDL is only called there).
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

    /// Waits until `ok` holds for the published state (the pad thread polls
    /// every few milliseconds).
    fn eventually(what: &str, ok: impl Fn() -> bool) {
        let t = Instant::now();
        while !ok() {
            assert!(t.elapsed() < Duration::from_secs(5), "timed out: {what}");
            thread::sleep(Duration::from_millis(5));
        }
    }

    /// The connected pads as the player lists them.
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

    /// The real SDL starts with our settings on this machine (the lesson of
    /// gilrs: a setting that made the library refuse to start went unseen
    /// while the tests used fakes).
    #[test]
    fn sdl_starts_with_our_settings() {
        let r = prismarine_pad_read();
        assert_eq!(r.unavailable, 0, "SDL did not start (see stderr)");
    }

    /// A virtual pad attached to the real SDL: listed by name, GUID and
    /// place; its buttons by position, sticks y up, triggers 0…1; Auto
    /// follows the pad last used; a chosen pad reads only itself. One test,
    /// so no other test's pads come and go meanwhile.
    #[test]
    fn virtual_pads_through_sdl() {
        assert_eq!(prismarine_pad_read().unavailable, 0);
        // Every button and axis SDL's gamepad has, in its own order, so the
        // virtual pad's raw index of each is its SDL code.
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

        // Positions: South is A (bit 0), East B, West X, North Y; the
        // shoulders, Back/Start, stick presses and d-pad in BUTTONS' order.
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
        // Guide is not one of the game's buttons.
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

        // A second pad of the same model: same GUID, the next place.
        let b = attach("prismarine test pad");
        eventually("two test pads", || {
            devices().iter().filter(|d| d.uuid == da.uuid).count() == 2
        });
        let db = devices()
            .into_iter()
            .find(|d| d.uuid == da.uuid && d.nth == 1)
            .unwrap();
        // Auto follows the pad last pressed; a chosen pad reads only itself.
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

        // Unplugged: listed no more, and the chosen pad reads as none.
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
