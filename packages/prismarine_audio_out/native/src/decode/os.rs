//! Thread roles: what each system is asked so a decode thread runs with the
//! threads that feed the device or below the frame's. `calls` is the
//! mapping, pure and tested on every platform; `apply` makes the calls. The
//! same roles as prismarine_jobs' thread_roles.dart.

/// A decode thread's role.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    /// Feeds what is heard next (the stream feeder: a chunk decoded late is
    /// heard as silence): macOS's user-interactive class.
    Feeder,
    /// Work no frame waits on yet (the decode cache's preloads): macOS's
    /// utility class.
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

/// What Linux lets a thread do with its nice: the process's nice (the
/// thread group leader's), the calling thread's, and RLIMIT_NICE's soft
/// limit (an unprivileged thread may lower its nice only down to
/// 20 - limit).
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
    /// Windows `SetThreadInformation(ThreadPowerThrottling)`, the execution
    /// speed bit: true EcoQoS (efficiency cores, a lower clock), false opted
    /// out.
    WinEcoQos(bool),
    /// Linux `setpriority(PRIO_PROCESS, 0, nice)`: the calling thread's
    /// nice (per thread on Linux).
    LinuxNice(i32),
    /// Linux `sched_setattr`: SCHED_OTHER at `nice`, asking for a slice of
    /// `slice_ns` (EEVDF's custom slice, 6.12 on; older kernels take the
    /// nice and ignore the slice). Where the call is refused, `setpriority`
    /// if `nice` is a change.
    LinuxFrame {
        nice: i32,
        slice_ns: u64,
        nice_changes: bool,
    },
    /// Linux `ioprio_set(IOPRIO_WHO_PROCESS, 0, ioprio)`: the calling
    /// thread's I/O priority.
    LinuxIoPrio(i32),
}

const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
const QOS_CLASS_UTILITY: u32 = 0x11;
const THREAD_PRIORITY_HIGHEST: i32 = 2;
const THREAD_PRIORITY_BELOW_NORMAL: i32 = -1;
/// Linux: the feeder's step above the process's nice where RLIMIT_NICE
/// allows it (the engine's raster thread on Android is at -5), and
/// background work's below it (`nice`'s own default step).
const FEEDER_STEP: i32 = 5;
const BACKGROUND_STEP: i32 = 10;
/// Linux I/O priorities (`linux/ioprio.h`): the best-effort class (2 << 13)
/// at its highest level for the feeder and its lowest for background
/// decodes, both allowed without privileges; not the idle class, behind
/// which a decode that a render waits on would wait for every other reader.
const IOPRIO_FEEDER: i32 = 0x4000;
const IOPRIO_BACKGROUND: i32 = 0x4007;
/// The feeder's slice on Linux 6.12 and later: shorter than the default
/// (0.75 ms × (1 + log2 CPUs), 3 ms from 8 CPUs), so EEVDF lets it preempt
/// on wakeup. Any thread may ask (0.1–100 ms).
const FEEDER_SLICE_NS: u64 = 1_000_000;

/// The calls that give a thread `role` on `os`. Windows: the feeder at the
/// highest normal priority, background work below normal (as the engine's
/// background threads), with EcoQoS off and on (Windows 11 puts EcoQoS
/// threads on the efficiency cores, as macOS does utility ones); not
/// background mode, whose very low I/O priority would stall a decode the
/// render waits on. Linux: the threads are this library's own and never serve
/// other work, so a nice raised for good is fine; a feeder asks for a short
/// slice and goes above the process only where RLIMIT_NICE allows, never
/// down; the best-effort I/O class at its highest and lowest levels.
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

/// Gives the calling thread `role` (refused quietly where the system won't).
/// A thread otherwise takes the class of the thread that made it, here
/// whichever Dart thread first needed it.
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
    // SAFETY: getpid and getpriority take and return plain integers; with
    // `who` 0 getpriority reads the calling thread, with the pid the thread
    // group's leader.
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
        // RLIM_INFINITY: any nice. rlim_t is narrower on 32-bit targets.
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
            // SAFETY: a plain system call about the calling thread; no pointers.
            unsafe { pthread_set_qos_class_self_np(class, 0) };
        }
        #[cfg(windows)]
        Call::WinPriority(p) => {
            use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority};
            // SAFETY: the calling thread's pseudo-handle and a priority; no
            // pointers.
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
            // SAFETY: plain integers; `who` 0 is the calling thread.
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
            // SAFETY: sched_setattr(pid 0: the calling thread, a live
            // sched_attr of the size it names, flags 0); no C wrapper.
            let r = unsafe {
                libc::syscall(
                    libc::SYS_sched_setattr,
                    0 as libc::c_long,
                    &attr as *const SchedAttr,
                    0 as libc::c_long,
                )
            };
            if r != 0 && nice_changes {
                // SAFETY: plain integers; `who` 0 is the calling thread.
                unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, nice) };
            }
        }
        #[cfg(any(target_os = "linux", target_os = "android"))]
        Call::LinuxIoPrio(ioprio) => {
            const IOPRIO_WHO_PROCESS: libc::c_long = 1; // who 0: this thread
                                                        // SAFETY: plain integers; no C wrapper.
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
        // Without RLIMIT_NICE: the slice and the I/O priority, its own nice.
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
        // Made by a lowered thread: back up as far as the limit allows.
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
