// What each system is asked so a thread runs as the frame's work or as
// background work: the two roles macOS calls user-interactive and utility
// QoS (perf, thread ownership). Pure: the system calls come in through
// [ThreadCalls], so the mapping is tested on every platform; thread_qos.dart
// gives it the real ones.

/// The systems with a mapping.
enum ThreadOs { macos, windows, linux, none }

/// The raw calls about the calling thread. Its "level" is the system's own
/// number for where the thread runs: the QoS class (macOS
/// `qos_class_self`), the priority (Windows `GetThreadPriority`) or the nice
/// value (Linux `getpriority(PRIO_PROCESS, 0)`, which is per thread there).
abstract interface class ThreadCalls {
  int level();
  void setLevel(int level);

  /// Windows `SetThreadInformation(ThreadPowerThrottling)`, the execution
  /// speed bit: true EcoQoS (the efficiency cores, a lower clock), false
  /// opted out, null left to the system.
  void setEcoQos(bool? on);

  /// Linux `sched_getscheduler`/`sched_setscheduler` for the calling thread.
  int policy();
  void setPolicy(int policy);

  /// Linux `ioprio_get`/`ioprio_set` (IOPRIO_WHO_PROCESS, 0: the calling
  /// thread); -1 where it can't be read.
  int ioPriority();
  void setIoPriority(int ioprio);

  /// Linux: the slice the calling thread asked for, in ns (`sched_getattr`'s
  /// sched_runtime; 0 on kernels before 6.12, which keep none for
  /// SCHED_OTHER).
  int slice();

  /// Linux `sched_setattr`: SCHED_OTHER at [nice], asking for [sliceNs]
  /// (EEVDF's custom slice, 6.12 on); false where refused.
  bool setFrameAttr(int nice, int sliceNs);
}

/// macOS QoS classes (`sys/qos.h`).
const macUserInteractive = 0x21, macUtility = 0x11, macDefault = 0x15;

/// Windows thread priorities (`processthreadsapi.h`).
const winAboveNormal = 1, winBelowNormal = -1;

/// Linux scheduling policies (`sched.h`).
const linuxSchedOther = 0, linuxSchedBatch = 3;

/// How far the frame's threads sit above the process's nice on Linux, where
/// RLIMIT_NICE allows it (the engine's raster thread on Android is at -5),
/// and background threads below it (`nice`'s own default step).
const linuxFrameStep = 5, linuxBackgroundStep = 10;

/// Linux I/O priorities (`linux/ioprio.h`): best-effort class (2 << 13) at
/// its highest level for the frame's reads and its lowest for background
/// ones; both allowed without privileges. Not the idle class: a load a
/// frame waits on would wait behind every other reader.
const linuxIoFrame = 0x4000, linuxIoBackground = 0x4007;

/// The slice a frame thread asks for on Linux 6.12 and later: shorter than
/// the default (0.75 ms × (1 + log2 CPUs), 3 ms from 8 CPUs), so EEVDF lets
/// it preempt on wakeup and gives its deadline sooner. Any thread may ask
/// (0.1–100 ms).
const linuxFrameSliceNs = 1000000;

/// The two roles on one system, given its raw calls and the facts read once
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

  /// The process runs below normal priority (`nice` above 0; a Windows
  /// priority class below normal). Unattended runs (heavy jobs, the land
  /// gate) run so: there a lowered thread ranks below every other such
  /// job's normal threads, and on a busy machine a scene load's workers
  /// starved for minutes. Such a process is already below interactive
  /// work, so its threads keep their place.
  final bool niced;

  /// Linux: the process's nice and RLIMIT_NICE's soft limit (an
  /// unprivileged thread may lower its nice only down to 20 - limit).
  final int processNice, rlimitNice;

  // Linux: whether the kernel keeps a requested slice (null: not tried).
  bool? _slices;

  int get _lowestNice => (20 - rlimitNice).clamp(-20, 20);

  /// Linux: the nice the frame's threads run at; above the process's only
  /// where RLIMIT_NICE allows it.
  int get frameNice => (processNice - linuxFrameStep)
      .clamp(_lowestNice, 20)
      .clamp(-20, processNice);

  /// Linux: the nice background work runs at.
  int get backgroundNice => (processNice + linuxBackgroundStep).clamp(-20, 19);

  /// Gives the calling thread the frame's role: macOS user-interactive;
  /// Windows above normal and out of EcoQoS (the engine's raster thread's
  /// priority); Linux a short slice (6.12 on), [frameNice] where RLIMIT_NICE
  /// allows it and the best-effort I/O class's highest level. Called per
  /// frame (Dart may run an isolate on any pool thread), so it reads first
  /// and sets only what differs.
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
    // The slice is set with the rest and a restore puts back all of it, so
    // a thread that kept it has the role: one read per frame.
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

  /// Gives the calling thread the background role for a while; returns
  /// what [restore] puts back (null: nothing changed). macOS utility;
  /// Windows below normal in EcoQoS (not background mode, whose very low
  /// I/O and memory priority would stall a load a frame waits on); Linux
  /// [backgroundNice] where the thread may come back from it, else
  /// SCHED_BATCH (pool threads serve other isolates next, and without
  /// RLIMIT_NICE a raised nice can't be lowered again), and the best-effort
  /// I/O class's lowest level.
  int? lower() {
    if (niced) return null;
    switch (os) {
      case ThreadOs.macos:
        final prev = calls.level();
        if (prev == macUtility) return null;
        calls.setLevel(macUtility);
        // Unspecified can't be set back; default is what such a thread
        // runs at.
        return prev == 0 ? macDefault : prev;
      case ThreadOs.windows:
        final prev = calls.level();
        // Above 15: GetThreadPriority's error value.
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
        // A frame thread was opted out; any other goes back to the system.
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

  /// Whether the calling thread runs in the frame's role (null: unknown).
  bool? inFrameRole() => switch (os) {
    ThreadOs.macos => calls.level() == macUserInteractive,
    ThreadOs.windows => calls.level() >= winAboveNormal,
    ThreadOs.linux =>
      calls.level() <= frameNice && calls.policy() == linuxSchedOther,
    ThreadOs.none => null,
  };
}

// Linux restore tokens: the CPU part in the low byte (kept, back to
// SCHED_OTHER, or the nice to set back), the I/O priority to set back above.
const _cpuKept = 0, _cpuBatch = 1, _cpuNice = 2, _cpuMask = 0xff;
const _ioSaved = 1 << 8, _ioShift = 12;
