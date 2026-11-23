// Maps the two thread roles, frame work and background work, to the calls of
// each system. The roles are user-interactive and utility QoS on macOS. The
// system calls come in through [ThreadCalls], which keeps the mapping
// testable on every platform. thread_qos.dart gives it the real calls.

/// The systems with a mapping.
enum ThreadOs { macos, windows, linux, none }

/// The raw calls about the calling thread. Its level is the number of the
/// system for the rank of the thread. The level is the QoS class
/// (`qos_class_self`) on macOS, the priority (`GetThreadPriority`) on
/// Windows and the nice value (`getpriority(PRIO_PROCESS, 0)`, per thread)
/// on Linux.
abstract interface class ThreadCalls {
  int level();
  void setLevel(int level);

  /// Sets the execution speed bit of `SetThreadInformation
  /// (ThreadPowerThrottling)` on Windows. True selects EcoQoS, with the
  /// efficiency cores and a lower clock. False opts out. Null leaves it to
  /// the system.
  void setEcoQos(bool? on);

  /// Linux `sched_getscheduler` and `sched_setscheduler` for the calling
  /// thread.
  int policy();
  void setPolicy(int policy);

  /// Linux `ioprio_get` and `ioprio_set` with IOPRIO_WHO_PROCESS and 0 for
  /// the calling thread. The getter returns -1 when it cannot be read.
  int ioPriority();
  void setIoPriority(int ioprio);

  /// Returns the slice in ns that the calling thread requested on Linux, the
  /// sched_runtime of `sched_getattr`. Kernels before 6.12 keep no slice for
  /// SCHED_OTHER and return 0.
  int slice();

  /// Calls `sched_setattr` on Linux with SCHED_OTHER at [nice] and the
  /// custom EEVDF slice [sliceNs] of Linux 6.12 and later. Returns false when
  /// the call is refused.
  bool setFrameAttr(int nice, int sliceNs);
}

/// macOS QoS classes (`sys/qos.h`).
const macUserInteractive = 0x21, macUtility = 0x11, macDefault = 0x15;

/// Windows thread priorities (`processthreadsapi.h`).
const winAboveNormal = 1, winBelowNormal = -1;

/// Linux scheduling policies (`sched.h`).
const linuxSchedOther = 0, linuxSchedBatch = 3;

/// The steps of the nice of frame threads above the nice of the process on
/// Linux, where RLIMIT_NICE allows it, and of background threads below it.
/// The raster thread of the engine on Android is at -5. The background step
/// is the default step of `nice`.
const linuxFrameStep = 5, linuxBackgroundStep = 10;

/// Linux I/O priorities from `linux/ioprio.h`. Frame reads use the highest
/// level of the best-effort class (2 << 13) and background reads its lowest
/// level. Both are allowed without privileges. The idle class is not used.
/// A load that a frame waits on would wait behind every other reader.
const linuxIoFrame = 0x4000, linuxIoBackground = 0x4007;

/// The slice that a frame thread requests on Linux 6.12 and later. The
/// default slice is 0.75 ms × (1 + log2 CPUs), 3 ms from 8 CPUs. EEVDF lets
/// a thread with a shorter slice preempt on wakeup and gives it an earlier
/// deadline. Any thread may request a slice of 0.1 ms to 100 ms.
const linuxFrameSliceNs = 1000000;

/// The two roles on one system, from its raw calls and the facts read once
/// per process.
class ThreadRoles {
  ThreadRoles(
    this.os,
    this.calls, {
    this.niced = false,
    this.processNice = 0,
    this.rlimitNice = 0,
  });

  final ThreadOs os;
  final ThreadCalls calls;

  /// True when the process runs below normal priority, with a `nice` above
  /// 0 or a Windows priority class below normal. The threads of such a
  /// process keep their place. A lowered thread would rank below the normal
  /// threads of every other niced process and could starve on a busy
  /// machine.
  final bool niced;

  /// The nice of the process and the soft limit of RLIMIT_NICE on Linux. A
  /// thread without privileges may lower its nice only down to 20 - limit.
  final int processNice, rlimitNice;

  // True when the Linux kernel keeps a requested slice, null before a try.
  bool? _slices;

  int get _lowestNice => (20 - rlimitNice).clamp(-20, 20);

  /// The nice of frame threads on Linux. It is above the nice of the process
  /// only where RLIMIT_NICE allows it.
  int get frameNice => (processNice - linuxFrameStep)
      .clamp(_lowestNice, 20)
      .clamp(-20, processNice);

  /// The nice of background work on Linux.
  int get backgroundNice => (processNice + linuxBackgroundStep).clamp(-20, 19);

  /// Gives the calling thread the frame role. The role is user-interactive
  /// on macOS. On Windows it is above normal and out of EcoQoS, the priority
  /// of the raster thread of the engine. On Linux it is a short slice from
  /// 6.12 on, [frameNice] where RLIMIT_NICE allows it and the highest level
  /// of the best-effort I/O class. Call it every frame, since Dart may run an
  /// isolate on any thread of its pool. It reads first and sets only the
  /// values that differ.
  void raise() {
    switch (os) {
      case ThreadOs.macos:
        if (calls.level() != macUserInteractive) {
          calls.setLevel(macUserInteractive);
        }
      case ThreadOs.windows:
        if (calls.level() != winAboveNormal) {
          calls.setLevel(winAboveNormal);
          calls.setEcoQos(false);
        }
      case ThreadOs.linux:
        _raiseLinux();
      case ThreadOs.none:
    }
  }

  void _raiseLinux() {
    // The slice is set with the rest of the role and a restore puts back all
    // of it. A thread that kept the slice has the role, which costs one read
    // per frame.
    if (_slices != false && calls.slice() == linuxFrameSliceNs) return;
    final now = calls.level();
    final f = frameNice;
    final nice = f >= _lowestNice && f < now ? f : now;
    if (_slices != false) {
      final kept =
          calls.setFrameAttr(nice, linuxFrameSliceNs) &&
          calls.slice() == linuxFrameSliceNs;
      _slices ??= kept;
      if (!kept && nice != now) calls.setLevel(nice);
    } else if (nice != now) {
      calls.setLevel(nice);
    }
    if (calls.ioPriority() != linuxIoFrame) calls.setIoPriority(linuxIoFrame);
  }

  /// Gives the calling thread the background role for a while. Returns the
  /// value that [restore] puts back, or null when nothing changed. The role
  /// is utility on macOS. On Windows it is below normal in EcoQoS. Background
  /// mode is not used, since its very low I/O and memory priority would stall
  /// a load that a frame waits on. On Linux it is [backgroundNice] where the
  /// thread may return from it, else SCHED_BATCH, with the lowest level of
  /// the best-effort I/O class. A raised nice cannot be lowered again without
  /// RLIMIT_NICE. A pool thread must return to its role for the next
  /// isolate.
  int? lower() {
    if (niced) return null;
    switch (os) {
      case ThreadOs.macos:
        final prev = calls.level();
        if (prev == macUtility) return null;
        calls.setLevel(macUtility);
        // Unspecified cannot be set back. Such a thread runs at default.
        return prev == 0 ? macDefault : prev;
      case ThreadOs.windows:
        final prev = calls.level();
        // A value above 15 is the error value of GetThreadPriority.
        if (prev <= winBelowNormal || prev > 15) return null;
        calls.setLevel(winBelowNormal);
        calls.setEcoQos(true);
        return prev;
      case ThreadOs.linux:
        final prev = calls.level();
        if (prev >= backgroundNice) return null;
        var cpu = _cpuKept;
        if (prev >= _lowestNice) {
          calls.setLevel(backgroundNice);
          cpu = _cpuNice + prev + 20;
        } else if (calls.policy() == linuxSchedOther) {
          calls.setPolicy(linuxSchedBatch);
          cpu = _cpuBatch;
        }
        final io = calls.ioPriority();
        final ioKept = io < 0 || io == linuxIoBackground;
        if (!ioKept) calls.setIoPriority(linuxIoBackground);
        if (cpu == _cpuKept && ioKept) return null;
        return cpu | (ioKept ? 0 : _ioSaved | io << _ioShift);
      case ThreadOs.none:
        return null;
    }
  }

  /// Puts back what [lower] returned.
  void restore(int? prev) {
    if (prev == null) return;
    switch (os) {
      case ThreadOs.macos:
        calls.setLevel(prev);
      case ThreadOs.windows:
        calls.setLevel(prev);
        // A frame thread was opted out. Any other thread goes back to the
        // system.
        calls.setEcoQos(prev >= winAboveNormal ? false : null);
      case ThreadOs.linux:
        final cpu = prev & _cpuMask;
        if (cpu == _cpuBatch) {
          calls.setPolicy(linuxSchedOther);
        } else if (cpu >= _cpuNice) {
          calls.setLevel(cpu - _cpuNice - 20);
        }
        if (prev & _ioSaved != 0) calls.setIoPriority(prev >> _ioShift);
      case ThreadOs.none:
    }
  }

  /// Returns true when the calling thread runs in the frame role, or null
  /// when it is unknown.
  bool? inFrameRole() => switch (os) {
    ThreadOs.macos => calls.level() == macUserInteractive,
    ThreadOs.windows => calls.level() >= winAboveNormal,
    ThreadOs.linux =>
      calls.level() <= frameNice && calls.policy() == linuxSchedOther,
    ThreadOs.none => null,
  };
}

// A Linux restore token holds the CPU part in the low byte and the I/O
// priority to set back above it. The CPU part is kept, back to SCHED_OTHER or
// the nice to set back.
const _cpuKept = 0, _cpuBatch = 1, _cpuNice = 2, _cpuMask = 0xff;
const _ioSaved = 1 << 8, _ioShift = 12;
