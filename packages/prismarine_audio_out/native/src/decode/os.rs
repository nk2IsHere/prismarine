//! Thread roles. Each system gets the calls that make a decode thread run
//! with the threads that feed the device or below the threads of the frame.
//! `calls` is the mapping, pure and tested on every platform. `apply` makes
//! the calls.

/// The role of a decode thread.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    /// Feeds the audio heard next, such as the stream feeder, where a chunk
    /// decoded late is heard as silence. It is the user-interactive class on
    /// macOS.
    Feeder,
    /// Work that no frame needs yet, such as the preloads of the decode cache.
    /// It is the utility class on macOS.
    Background,
}

/// The systems with a mapping.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Os {
    Mac,
    Windows,
    Linux,
    Other,
}

/// The nice values that limit a thread on Linux. They are the nice of the
/// process, which is that of the thread group leader, the nice of the
/// calling thread and the soft limit of RLIMIT_NICE. A thread without
/// privileges may lower its nice only down to 20 - limit.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Nice {
    pub process: i32,
    pub thread: i32,
    pub rlimit: u64,
}

/// One system call.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Call {
    /// macOS `pthread_set_qos_class_self_np(class, 0)`.
    MacQos(u32),
    /// Windows `SetThreadPriority(GetCurrentThread(), priority)`.
    WinPriority(i32),
    /// Windows `SetThreadInformation(ThreadPowerThrottling)` with the
    /// execution speed bit. True selects EcoQoS with the efficiency cores and
    /// a lower clock. False opts out.
    WinEcoQos(bool),
    /// Linux `setpriority(PRIO_PROCESS, 0, nice)`, the nice of the calling
    /// thread, which is per thread on Linux.
    LinuxNice(i32),
    /// Linux `sched_setattr` with SCHED_OTHER at `nice` and a slice of
    /// `slice_ns`, the custom slice of EEVDF from Linux 6.12. Older kernels
    /// take the nice and ignore the slice. A refused call falls back to
    /// `setpriority` if `nice` is a change.
    LinuxFrame {
        nice: i32,
        slice_ns: u64,
        nice_changes: bool,
    },
    /// Linux `ioprio_set(IOPRIO_WHO_PROCESS, 0, ioprio)`, the I/O priority of
    /// the calling thread.
    LinuxIoPrio(i32),
}

const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
const QOS_CLASS_UTILITY: u32 = 0x11;
const THREAD_PRIORITY_HIGHEST: i32 = 2;
const THREAD_PRIORITY_BELOW_NORMAL: i32 = -1;
/// The steps on Linux of the nice of the feeder above the nice of the process, where RLIMIT_NICE
/// allows it, with the step of background work below it. The raster thread of the engine on Android
/// is at -5. The background step is the default step of `nice`.
const FEEDER_STEP: i32 = 5;
const BACKGROUND_STEP: i32 = 10;
/// Linux I/O priorities from `linux/ioprio.h`. The feeder uses the highest
/// level of the best-effort class (2 << 13) and background decodes its
/// lowest level. Both are allowed without privileges. The idle class is not
/// used. A decode that a render needs would wait behind every other reader.
const IOPRIO_FEEDER: i32 = 0x4000;
const IOPRIO_BACKGROUND: i32 = 0x4007;
/// The slice of the feeder on Linux 6.12 and later. The default slice is
/// 0.75 ms × (1 + log2 CPUs), 3 ms from 8 CPUs. EEVDF lets a thread with a
/// shorter slice preempt on wakeup. Any thread may request a slice of 0.1 ms
/// to 100 ms.
const FEEDER_SLICE_NS: u64 = 1_000_000;

/// Returns the calls that give a thread `role` on `os` with the limits `nice`.
///
/// On Windows the feeder runs at the highest normal priority without EcoQoS. Background work runs
/// below normal with EcoQoS. Background mode is not used, since its very low I/O priority would
/// stall a decode that the render needs.
///
/// On Linux the threads belong to this library and serve no other work. A nice raised for good is
/// fine. A feeder requests a short slice and goes above the process only where RLIMIT_NICE allows
/// it. It does not go lower. The I/O priority is the highest or lowest level of the best-effort
/// class.
pub fn calls(os: Os, role: Role, nice: Nice) -> [Option<Call>; 2] {
    match (os, role) {
        (Os::Mac, Role::Feeder) => [Some(Call::MacQos(QOS_CLASS_USER_INTERACTIVE)), None],
        (Os::Mac, Role::Background) => [Some(Call::MacQos(QOS_CLASS_UTILITY)), None],
        (Os::Windows, Role::Feeder) => [
            Some(Call::WinPriority(THREAD_PRIORITY_HIGHEST)),
            Some(Call::WinEcoQos(false)),
        ],
        (Os::Windows, Role::Background) => [
            Some(Call::WinPriority(THREAD_PRIORITY_BELOW_NORMAL)),
            Some(Call::WinEcoQos(true)),
        ],
        (Os::Linux, Role::Feeder) => {
            let lowest = 20 - nice.rlimit.min(40) as i32;
            let target = (nice.process - FEEDER_STEP).max(lowest);
            let nice_changes = target < nice.thread;
            [
                Some(Call::LinuxFrame {
                    nice: if nice_changes { target } else { nice.thread },
                    slice_ns: FEEDER_SLICE_NS,
                    nice_changes,
                }),
                Some(Call::LinuxIoPrio(IOPRIO_FEEDER)),
            ]
        }
        (Os::Linux, Role::Background) => {
            let target = (nice.process + BACKGROUND_STEP).min(19);
            [
                (target > nice.thread).then_some(Call::LinuxNice(target)),
                Some(Call::LinuxIoPrio(IOPRIO_BACKGROUND)),
            ]
        }
        (Os::Other, _) => [None, None],
    }
}

/// Gives the calling thread `role`. A system that refuses it does so
/// quietly. A thread otherwise takes the class of the thread that made it,
/// here the Dart thread that first needed it.
pub fn take_role(role: Role) {
    for call in calls(this_os(), role, read_nice()).into_iter().flatten() {
        apply(call);
    }
}

fn this_os() -> Os {
    if cfg!(target_os = "macos") {
        Os::Mac
    } else if cfg!(windows) {
        Os::Windows
    } else if cfg!(any(target_os = "linux", target_os = "android")) {
        Os::Linux
    } else {
        Os::Other
    }
}

#[cfg(all(any(target_os = "linux", target_os = "android"), not(miri)))]
fn read_nice() -> Nice {
    let mut lim = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: getrlimit writes one rlimit through a pointer to a live local.
    let ok = unsafe { libc::getrlimit(libc::RLIMIT_NICE, &mut lim) } == 0;
    // SAFETY: getpid and getpriority take and return plain integers. With
    // `who` 0 getpriority reads the calling thread and with the pid the
    // leader of the thread group.
    let (process, thread) = unsafe {
        let pid = libc::getpid() as libc::id_t;
        (
            libc::getpriority(libc::PRIO_PROCESS, pid),
            libc::getpriority(libc::PRIO_PROCESS, 0),
        )
    };
    Nice {
        process,
        thread,
        // RLIM_INFINITY allows any nice. rlim_t is narrower on 32-bit targets.
        #[allow(clippy::unnecessary_cast)]
        rlimit: if ok { lim.rlim_cur as u64 } else { 0 },
    }
}

#[cfg(not(all(any(target_os = "linux", target_os = "android"), not(miri))))]
fn read_nice() -> Nice {
    Nice::default()
}

/// struct sched_attr, SCHED_ATTR_SIZE_VER0 (include/uapi/linux/sched/types.h).
#[cfg(all(any(target_os = "linux", target_os = "android"), not(miri)))]
#[repr(C)]
#[derive(Default)]
struct SchedAttr {
    size: u32,
    policy: u32,
    flags: u64,
    nice: i32,
    priority: u32,
    runtime: u64,
    deadline: u64,
    period: u64,
}

#[cfg(miri)]
fn apply(_: Call) {}

#[cfg(not(miri))]
fn apply(call: Call) {
    match call {
        #[cfg(target_os = "macos")]
        Call::MacQos(class) => {
            extern "C" {
                fn pthread_set_qos_class_self_np(qos: u32, relative_priority: i32) -> i32;
            }
            // SAFETY: a plain system call about the calling thread without
            // pointers.
            unsafe { pthread_set_qos_class_self_np(class, 0) };
        }
        #[cfg(windows)]
        Call::WinPriority(p) => {
            use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority};
            // SAFETY: the pseudo-handle of the calling thread and a priority,
            // without pointers.
            unsafe { SetThreadPriority(GetCurrentThread(), p) };
        }
        #[cfg(windows)]
        Call::WinEcoQos(on) => {
            use windows_sys::Win32::System::Threading::{
                GetCurrentThread, SetThreadInformation, ThreadPowerThrottling,
                THREAD_POWER_THROTTLING_CURRENT_VERSION, THREAD_POWER_THROTTLING_EXECUTION_SPEED,
                THREAD_POWER_THROTTLING_STATE,
            };
            let state = THREAD_POWER_THROTTLING_STATE {
                Version: THREAD_POWER_THROTTLING_CURRENT_VERSION,
                ControlMask: THREAD_POWER_THROTTLING_EXECUTION_SPEED,
                StateMask: if on {
                    THREAD_POWER_THROTTLING_EXECUTION_SPEED
                } else {
                    0
                },
            };
            // SAFETY: the struct is a live local of the size passed, read
            // only during the call. Refused before Windows 10 1709.
            unsafe {
                SetThreadInformation(
                    GetCurrentThread(),
                    ThreadPowerThrottling,
                    (&state as *const THREAD_POWER_THROTTLING_STATE).cast(),
                    std::mem::size_of::<THREAD_POWER_THROTTLING_STATE>() as u32,
                )
            };
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        Call::LinuxNice(n) => {
            // SAFETY: plain integers. `who` 0 is the calling thread.
            unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, n) };
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        Call::LinuxFrame {
            nice,
            slice_ns,
            nice_changes,
        } => {
            let attr = SchedAttr {
                size: std::mem::size_of::<SchedAttr>() as u32,
                policy: libc::SCHED_OTHER as u32,
                nice,
                runtime: slice_ns,
                ..SchedAttr::default()
            };
            // SAFETY: sched_setattr with pid 0 for the calling thread, a live
            // sched_attr of the size in its field and flags 0, without a C
            // wrapper.
            let r = unsafe {
                libc::syscall(
                    libc::SYS_sched_setattr,
                    0 as libc::c_long,
                    &attr as *const SchedAttr,
                    0 as libc::c_long,
                )
            };
            if r != 0 && nice_changes {
                // SAFETY: plain integers. `who` 0 is the calling thread.
                unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, nice) };
            }
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        Call::LinuxIoPrio(ioprio) => {
            // With who 0, IOPRIO_WHO_PROCESS selects this thread.
            const IOPRIO_WHO_PROCESS: libc::c_long = 1;
            // SAFETY: plain integers, without a C wrapper.
            unsafe {
                libc::syscall(
                    libc::SYS_ioprio_set,
                    IOPRIO_WHO_PROCESS,
                    0 as libc::c_long,
                    ioprio as libc::c_long,
                )
            };
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: Nice = Nice {
        process: 0,
        thread: 0,
        rlimit: 0,
    };

    #[test]
    fn macos_classes() {
        assert_eq!(
            calls(Os::Mac, Role::Feeder, NONE),
            [Some(Call::MacQos(0x21)), None]
        );
        assert_eq!(
            calls(Os::Mac, Role::Background, NONE),
            [Some(Call::MacQos(0x11)), None]
        );
    }

    #[test]
    fn windows_priority_and_ecoqos() {
        assert_eq!(
            calls(Os::Windows, Role::Feeder, NONE),
            [Some(Call::WinPriority(2)), Some(Call::WinEcoQos(false))]
        );
        assert_eq!(
            calls(Os::Windows, Role::Background, NONE),
            [Some(Call::WinPriority(-1)), Some(Call::WinEcoQos(true))]
        );
    }

    fn feeder(nice: i32, nice_changes: bool) -> [Option<Call>; 2] {
        [
            Some(Call::LinuxFrame {
                nice,
                slice_ns: 1_000_000,
                nice_changes,
            }),
            Some(Call::LinuxIoPrio(0x4000)),
        ]
    }

    #[test]
    fn linux_background_steps_from_the_process_with_low_io() {
        assert_eq!(
            calls(Os::Linux, Role::Background, NONE),
            [Some(Call::LinuxNice(10)), Some(Call::LinuxIoPrio(0x4007))]
        );
        let niced = Nice {
            process: 15,
            thread: 15,
            rlimit: 0,
        };
        assert_eq!(
            calls(Os::Linux, Role::Background, niced)[0],
            Some(Call::LinuxNice(19))
        );
        let already = Nice {
            process: 0,
            thread: 12,
            rlimit: 0,
        };
        assert_eq!(
            calls(Os::Linux, Role::Background, already),
            [None, Some(Call::LinuxIoPrio(0x4007))]
        );
    }

    #[test]
    fn linux_feeder_slice_io_and_the_nice_the_limit_allows() {
        // Without RLIMIT_NICE the feeder gets the slice and the I/O priority
        // at its own nice.
        assert_eq!(calls(Os::Linux, Role::Feeder, NONE), feeder(0, false));
        let some = Nice {
            process: 0,
            thread: 0,
            rlimit: 23,
        };
        assert_eq!(calls(Os::Linux, Role::Feeder, some), feeder(-3, true));
        let any = Nice {
            process: 0,
            thread: 0,
            rlimit: u64::MAX,
        };
        assert_eq!(calls(Os::Linux, Role::Feeder, any), feeder(-5, true));
        // A thread made by a lowered thread goes back up as far as the limit
        // allows.
        let made_low = Nice {
            process: 0,
            thread: 10,
            rlimit: 20,
        };
        assert_eq!(calls(Os::Linux, Role::Feeder, made_low), feeder(0, true));
    }

    #[test]
    fn elsewhere_nothing() {
        assert_eq!(calls(Os::Other, Role::Feeder, NONE), [None, None]);
        assert_eq!(calls(Os::Other, Role::Background, NONE), [None, None]);
    }
}
