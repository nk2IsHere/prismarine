// The calling thread's role through the system's own calls (thread_roles.dart
// has the mapping): the frame's work up with the UI's threads, background
// work below them (perf, thread ownership). Each isolate looks the calls up
// once; the calls are leaf calls and allocate nothing.
import 'dart:ffi';
import 'dart:io' show Platform;

import 'thread_linux.dart';
import 'thread_roles.dart';

/// Gives the calling thread the frame's role (the sim's tick, the plan's
/// build: work the UI's frame waits on). Cheap when it already has it.
void raiseThreadQos() => _roles?.raise();

/// Gives the calling thread the background role; returns what to restore
/// (null: nothing changed). Not in a niced process ([processNiced]).
int? lowerThreadQos() => _roles?.lower();

/// Restores [prev] from [lowerThreadQos].
void restoreThreadQos(int? prev) => _roles?.restore(prev);

/// Whether the calling thread has the frame's role (null: unknown here).
bool? threadHasFrameRole() => _roles?.inFrameRole();

/// Whether this process runs below normal priority: `nice` above 0 (macOS,
/// Linux) or a priority class below normal (Windows); see
/// [ThreadRoles.niced].
bool get processNiced => _roles?.niced ?? false;

final ThreadRoles? _roles = () {
  try {
    if (Platform.isMacOS) return _macRoles();
    if (Platform.isWindows) return _windowsRoles();
    if (Platform.isLinux || Platform.isAndroid) return linuxThreadRoles();
  } on Object {
    // A system without one of the calls keeps the default scheduling.
  }
  return null;
}();

typedef _Get = int Function();
typedef _Set = void Function(int);

// macOS and Windows: a level and (Windows) EcoQoS; the Linux calls are
// never made there.
class _Calls implements ThreadCalls {
  _Calls(this._level, this._setLevel, {this.eco});

  final _Get _level;
  final _Set _setLevel;
  final void Function(bool? on)? eco;

  @override
  int level() => _level();
  @override
  void setLevel(int level) => _setLevel(level);
  @override
  void setEcoQos(bool? on) => eco?.call(on);
  @override
  int policy() => linuxSchedOther;
  @override
  void setPolicy(int policy) {}
  @override
  int ioPriority() => -1;
  @override
  void setIoPriority(int ioprio) {}
  @override
  int slice() => 0;
  @override
  bool setFrameAttr(int nice, int sliceNs) => false;
}

ThreadRoles _macRoles() {
  final lib = DynamicLibrary.process();
  final self = lib.lookupFunction<Uint32 Function(), int Function()>(
    'qos_class_self',
    isLeaf: true,
  );
  final set = lib
      .lookupFunction<Int32 Function(Uint32, Int32), int Function(int, int)>(
        'pthread_set_qos_class_self_np',
        isLeaf: true,
      );
  final getpriority = lib
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'getpriority',
        isLeaf: true,
      );
  return ThreadRoles(
    ThreadOs.macos,
    _Calls(self, (c) => set(c, 0)),
    niced: getpriority(0, 0) > 0, // PRIO_PROCESS, this process
  );
}

// THREAD_POWER_THROTTLING_STATE {Version, ControlMask, StateMask} three
// times (ULONGs, 12 bytes each, winnt.h; version 1, the execution speed
// bit 1): left to the system, EcoQoS, opted out. One block per isolate,
// freed with it (one-shot job isolates come and go).
final Pointer<Uint8> _structs = () {
  final p = nativeBlock(36);
  final u32 = p.cast<Uint32>();
  for (var i = 0; i < 3; i++) {
    u32[i * 3] = 1;
  }
  u32[4] = u32[5] = u32[7] = 1;
  return p;
}();

ThreadRoles _windowsRoles() {
  final k = DynamicLibrary.open('kernel32.dll');
  // Pseudo-handles: always "the calling thread" / "this process".
  final thread = k.lookupFunction<IntPtr Function(), int Function()>(
    'GetCurrentThread',
  )();
  final process = k.lookupFunction<IntPtr Function(), int Function()>(
    'GetCurrentProcess',
  )();
  final getPriority = k
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'GetThreadPriority',
        isLeaf: true,
      );
  final setPriority = k
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'SetThreadPriority',
        isLeaf: true,
      );
  // Windows 8 and later; the power throttling class since Windows 10 1709
  // (refused quietly before).
  final setInfo = k
      .lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Uint32>, Uint32),
        int Function(int, int, Pointer<Uint32>, int)
      >('SetThreadInformation', isLeaf: true);
  final priorityClass = k
      .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'GetPriorityClass',
      )(process);
  const threadPowerThrottling = 3; // THREAD_INFORMATION_CLASS
  final system = _structs.cast<Uint32>();
  final ecoOn = (_structs + 12).cast<Uint32>();
  final ecoOff = (_structs + 24).cast<Uint32>();
  return ThreadRoles(
    ThreadOs.windows,
    _Calls(
      () => getPriority(thread),
      (p) => setPriority(thread, p),
      eco: (on) => setInfo(
        thread,
        threadPowerThrottling,
        on == null ? system : (on ? ecoOn : ecoOff),
        12,
      ),
    ),
    // IDLE_PRIORITY_CLASS, BELOW_NORMAL_PRIORITY_CLASS
    niced: priorityClass == 0x40 || priorityClass == 0x4000,
  );
}
