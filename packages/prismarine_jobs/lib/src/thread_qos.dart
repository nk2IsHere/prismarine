// The role of the calling thread through the calls of the system. The
// mapping is in thread_roles.dart. Frame work runs with the threads of the
// UI and background work below them. Each isolate looks the calls up once.
// The calls are leaf calls and allocate nothing.
import 'dart:ffi';
import 'dart:io' show Platform;

import 'thread_linux.dart';
import 'thread_roles.dart';

/// Gives the calling thread the frame role, for work that holds up the frame of
/// the UI. Cheap when the thread already has the role.
void raiseThreadQos() => _roles?.raise();

/// Gives the calling thread the background role. Returns the value to
/// restore, or null when nothing changed. A niced process ([processNiced])
/// keeps its roles.
int? lowerThreadQos() => _roles?.lower();

/// Restores [prev] from [lowerThreadQos].
void restoreThreadQos(int? prev) => _roles?.restore(prev);

/// Returns true when the calling thread has the frame role, or null when it
/// is unknown on this system.
bool? threadHasFrameRole() => _roles?.inFrameRole();

/// True when this process runs below normal priority, with a `nice` above 0
/// on macOS and Linux or a priority class below normal on Windows. See
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

// The calls of macOS and Windows set a level and, on Windows, EcoQoS. The
// Linux calls are not made there.
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

// Three THREAD_POWER_THROTTLING_STATE structs {Version, ControlMask,
// StateMask} of ULONGs, 12 bytes each, from winnt.h with version 1 and the
// execution speed bit 1. They are left to the system, EcoQoS and opted out.
// Each isolate has one block, freed with the isolate.
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
  // Pseudo-handles for the calling thread and this process.
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
  // Windows 8 and later have the call. Windows 10 1709 and later have the
  // power throttling class. Older versions refuse it quietly.
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
    // IDLE_PRIORITY_CLASS or BELOW_NORMAL_PRIORITY_CLASS
    niced: priorityClass == 0x40 || priorityClass == 0x4000,
  );
}
