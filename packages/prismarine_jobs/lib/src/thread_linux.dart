// The Linux calls for thread_roles.dart, with the nice, scheduling policy,
// EEVDF slice and I/O priority of a thread. ioprio and sched_{get,set}attr
// have no C library wrappers in common glibc versions. They are called
// through syscall(2) by number.
import 'dart:ffi';
import 'dart:io' show pid;

import 'package:ffi/ffi.dart' show malloc;

import 'thread_roles.dart';

/// A zeroed native block of [bytes], freed with the calling isolate.
Pointer<Uint8> nativeBlock(int bytes) {
  final p = malloc<Uint8>(bytes);
  for (var i = 0; i < bytes; i++) {
    p[i] = 0;
  }
  final owner = _BlockOwner();
  _freeing.attach(owner, p.cast(), externalSize: bytes);
  _owners.add(owner);
  return p;
}

final _freeing = NativeFinalizer(malloc.nativeFree);
// The owner of each block is kept as long as the globals of the isolate.
final _owners = <_BlockOwner>[];

final class _BlockOwner implements Finalizable {}

/// Returns the syscall numbers of ioprio_set, ioprio_get, sched_setattr and
/// sched_getattr on this ABI, or null on another ABI. The numbers are from
/// arch/x86/entry/syscalls/syscall_64.tbl and, for arm64 and riscv64, from
/// the generic table include/uapi/asm-generic/unistd.h.
(int, int, int, int)? _numbers() => switch (Abi.current()) {
  Abi.linuxX64 || Abi.androidX64 => (251, 252, 314, 315),
  Abi.linuxArm64 || Abi.androidArm64 || Abi.linuxRiscv64 => (30, 31, 274, 275),
  _ => null,
};

const _ioprioWhoProcess = 1; // the calling thread with who 0
// The fields of struct sched_attr at SCHED_ATTR_SIZE_VER0, from
// include/uapi/linux/sched/types.h, are size u32 @0, policy u32 @4, flags
// u64 @8, nice s32 @16, priority u32 @20, runtime u64 @24, deadline u64 @32
// and period u64 @40.
const _attrSize = 48;

/// The roles on Linux.
ThreadRoles linuxThreadRoles() {
  final lib = DynamicLibrary.process();
  // On Linux PRIO_PROCESS with who 0 is the calling thread and not the
  // process, as setpriority(2) states under BUGS.
  final getpriority = lib
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'getpriority',
        isLeaf: true,
      );
  final setpriority = lib
      .lookupFunction<
        Int32 Function(Int32, Uint32, Int32),
        int Function(int, int, int)
      >('setpriority', isLeaf: true);
  final getScheduler = lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'sched_getscheduler',
        isLeaf: true,
      );
  final setScheduler = lib
      .lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Int32>),
        int Function(int, int, Pointer<Int32>)
      >('sched_setscheduler', isLeaf: true);
  // syscall(2) reads its arguments as longs.
  final sys2 = lib
      .lookupFunction<
        Long Function(Long, VarArgs<(Long, Long)>),
        int Function(int, int, int)
      >('syscall', isLeaf: true);
  final sys3 = lib
      .lookupFunction<
        Long Function(Long, VarArgs<(Long, Long, Long)>),
        int Function(int, int, int, int)
      >('syscall', isLeaf: true);
  final sys4 = lib
      .lookupFunction<
        Long Function(Long, VarArgs<(Long, Long, Long, Long)>),
        int Function(int, int, int, int, int)
      >('syscall', isLeaf: true);
  // The block holds rlimit {rlim_cur, rlim_max} @0, sched_param {0} @16 and
  // sched_attr @24.
  final block = nativeBlock(24 + _attrSize);
  var rlimitNice = 0;
  if (sizeOf<IntPtr>() == 8) {
    final getrlimit = lib
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>)
        >('getrlimit', isLeaf: true);
    const rlimitNiceResource = 13; // RLIMIT_NICE
    final rlimit = block.cast<Uint64>();
    if (getrlimit(rlimitNiceResource, rlimit) == 0) {
      // RLIM_INFINITY reads as a negative int and allows any nice.
      final cur = rlimit[0];
      rlimitNice = cur > 40 || cur < 0 ? 40 : cur;
    }
  }
  // The nice of the main thread, the leader of the thread group, is the nice
  // of the process.
  final processNice = getpriority(0, pid);
  return ThreadRoles(
    ThreadOs.linux,
    _LinuxCalls(
      getpriority: getpriority,
      setpriority: setpriority,
      getScheduler: getScheduler,
      setScheduler: setScheduler,
      sys2: sys2,
      sys3: sys3,
      sys4: sys4,
      param: (block + 16).cast(),
      attr: block + 24,
      numbers: _numbers(),
    ),
    niced: processNice > 0,
    processNice: processNice,
    rlimitNice: rlimitNice,
  );
}

class _LinuxCalls implements ThreadCalls {
  _LinuxCalls({
    required this.getpriority,
    required this.setpriority,
    required this.getScheduler,
    required this.setScheduler,
    required this.sys2,
    required this.sys3,
    required this.sys4,
    required this.param,
    required this.attr,
    required this.numbers,
  }) : _nice = (attr + 16).cast(),
       _runtime = (attr + 24).cast();

  final int Function(int, int) getpriority;
  final int Function(int, int, int) setpriority;
  final int Function(int) getScheduler;
  final int Function(int, int, Pointer<Int32>) setScheduler;
  final int Function(int, int, int) sys2;
  final int Function(int, int, int, int) sys3;
  final int Function(int, int, int, int, int) sys4;
  final Pointer<Int32> param;
  final Pointer<Uint8> attr;
  final (int, int, int, int)? numbers;
  final Pointer<Int32> _nice;
  final Pointer<Uint64> _runtime;

  @override
  int level() => getpriority(0, 0);
  @override
  void setLevel(int level) => setpriority(0, 0, level);
  @override
  void setEcoQos(bool? on) {}
  @override
  int policy() => getScheduler(0) & ~0x40000000; // SCHED_RESET_ON_FORK
  @override
  void setPolicy(int policy) => setScheduler(0, policy, param);

  @override
  int ioPriority() {
    final n = numbers;
    return n == null ? -1 : sys2(n.$2, _ioprioWhoProcess, 0);
  }

  @override
  void setIoPriority(int ioprio) {
    final n = numbers;
    if (n != null) sys3(n.$1, _ioprioWhoProcess, 0, ioprio);
  }

  @override
  int slice() {
    final n = numbers;
    if (n == null || sys4(n.$4, 0, attr.address, _attrSize, 0) != 0) return 0;
    return _runtime.value;
  }

  @override
  bool setFrameAttr(int nice, int sliceNs) {
    final n = numbers;
    if (n == null) return false;
    final w = attr.cast<Uint32>();
    for (var i = 0; i < _attrSize ~/ 4; i++) {
      w[i] = 0;
    }
    w[0] = _attrSize;
    w[1] = linuxSchedOther;
    _nice.value = nice;
    _runtime.value = sliceNs;
    return sys3(n.$3, 0, attr.address, 0) == 0;
  }
}
