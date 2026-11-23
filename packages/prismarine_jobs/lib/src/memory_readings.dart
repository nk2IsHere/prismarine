// The OS's memory readings behind MemoryRoom: macOS through sysctl and
// proc_pid_rusage, Linux through /proc and the cgroup v2 files, Windows
// through kernel32 (GlobalMemoryStatusEx, K32GetProcessMemoryInfo and a
// low-memory resource notification).
import 'dart:ffi';
import 'dart:io';

/// One look at the machine's memory, in MB.
class MemoryReadings {
  const MemoryReadings({
    required this.physicalMb,
    required this.processMb,
    this.availableMb,
    this.cgroupRoomMb,
    this.commitRoomMb,
    this.pagedOutMb = 0,
    this.pressure = false,
  });

  /// The machine's physical memory.
  final int physicalMb;

  /// The process's own: macOS its footprint, Linux its resident set,
  /// Windows its private bytes.
  final int processMb;

  /// Available to the system without paging (Linux `MemAvailable`,
  /// Windows `ullAvailPhys`); null where the OS gives no such figure
  /// (macOS: free pages say little next to its file cache).
  final int? availableMb;

  /// Room under the process's cgroup v2 memory limit (Linux; null without
  /// one): the limit less what it holds, reclaimable file pages not counted.
  final int? cgroupRoomMb;

  /// Room under the commit limit (Windows `ullAvailPageFile`).
  final int? commitRoomMb;

  /// Paged out so far, a running total compared between looks (Linux
  /// `pswpout`, macOS the swap file's use; 0 where unknown).
  final int pagedOutMb;

  /// The OS says memory is short: macOS's pressure level above normal,
  /// Windows' low-memory resource notification or a memory load of 90 %.
  final bool pressure;

  @override
  String toString() =>
      'physical $physicalMb, process $processMb'
      '${availableMb == null ? '' : ', available $availableMb'}'
      '${cgroupRoomMb == null ? '' : ', cgroup room $cgroupRoomMb'}'
      '${commitRoomMb == null ? '' : ', commit room $commitRoomMb'}'
      ', paged out $pagedOutMb${pressure ? ', pressure' : ''}';
}

/// This machine's readings now (throws where the OS gives none).
MemoryReadings readMemory() {
  if (Platform.isMacOS) return _mac();
  if (Platform.isLinux) return _linux();
  if (Platform.isWindows) return _windows();
  throw UnsupportedError('no memory readings on ${Platform.operatingSystem}');
}

// --- Linux -----------------------------------------------------------------

MemoryReadings _linux() {
  final m = _meminfo();
  return MemoryReadings(
    physicalMb: (m['MemTotal'] ?? 0) >> 10,
    processMb: ProcessInfo.currentRss >> 20,
    availableMb: (m['MemAvailable'] ?? 0) >> 10,
    cgroupRoomMb: _cgroupRoomMb(),
    // pswpout counts pages (4 KB).
    pagedOutMb: _vmstat('pswpout') >> 8,
  );
}

Map<String, int> _meminfo() {
  final out = <String, int>{};
  for (final l in File('/proc/meminfo').readAsLinesSync()) {
    final colon = l.indexOf(':');
    if (colon < 0) continue;
    final v = int.tryParse(l.substring(colon + 1).trim().split(' ').first);
    if (v != null) out[l.substring(0, colon)] = v;
  }
  return out;
}

int _vmstat(String key) {
  for (final l in File('/proc/vmstat').readAsLinesSync()) {
    if (l.startsWith('$key ')) return int.parse(l.substring(key.length + 1));
  }
  return 0;
}

/// The tightest room under a cgroup v2 memory limit along the process's
/// cgroup path; null without a limit.
int? _cgroupRoomMb() {
  final self = File('/proc/self/cgroup');
  if (!self.existsSync()) return null;
  final line = self.readAsLinesSync().firstWhere(
    (l) => l.startsWith('0::'),
    orElse: () => '',
  );
  if (line.isEmpty) return null;
  int? room;
  for (var path = line.substring(3); path.isNotEmpty;) {
    final dir = '/sys/fs/cgroup$path';
    final max = File('$dir/memory.max');
    if (max.existsSync()) {
      final limit = int.tryParse(max.readAsStringSync().trim());
      if (limit != null) {
        final current = int.parse(
          File('$dir/memory.current').readAsStringSync().trim(),
        );
        var inactive = 0;
        for (final l in File('$dir/memory.stat').readAsLinesSync()) {
          if (l.startsWith('inactive_file ')) {
            inactive = int.parse(l.substring(14));
          }
        }
        final r = (limit - current + inactive) >> 20;
        if (room == null || r < room) room = r;
      }
    }
    final up = path.lastIndexOf('/');
    path = up <= 0 ? '' : path.substring(0, up);
  }
  return room;
}

// --- macOS -----------------------------------------------------------------

MemoryReadings _mac() {
  // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
  final level = _sysctl('kern.memorystatus_vm_pressure_level') ?? 4;
  return MemoryReadings(
    physicalMb: (_sysctl('hw.memsize') ?? 0) >> 20,
    processMb: (_footprint() ?? 0) >> 20,
    // vm.swapusage is an xsw_usage: total, avail, used (u64 each).
    pagedOutMb: (_sysctl('vm.swapusage', at: 16, size: 32) ?? 0) >> 20,
    pressure: level != 1,
  );
}

final _libc = Platform.isMacOS ? DynamicLibrary.process() : null;
final _sysctlbyname = _libc
    ?.lookupFunction<
      Int32 Function(
        Pointer<Uint8>,
        Pointer<Void>,
        Pointer<IntPtr>,
        Pointer<Void>,
        IntPtr,
      ),
      int Function(
        Pointer<Uint8>,
        Pointer<Void>,
        Pointer<IntPtr>,
        Pointer<Void>,
        int,
      )
    >('sysctlbyname');
final _rusage = _libc
    ?.lookupFunction<
      Int32 Function(Int32, Int32, Pointer<Void>),
      int Function(int, int, Pointer<Void>)
    >('proc_pid_rusage');

/// 1 KB of scratch for the calls, kept for the isolate's life.
Pointer<Uint8> get _scratch => _buf ??= _alloc(1024);
Pointer<Uint8>? _buf;

Pointer<Uint8> _alloc(int bytes) {
  if (Platform.isWindows) {
    final localAlloc = _kernel32!
        .lookupFunction<
          Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)
        >('LocalAlloc');
    return localAlloc(0x40, bytes).cast(); // LPTR: fixed, zeroed
  }
  final malloc = DynamicLibrary.process()
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  return malloc(bytes).cast();
}

/// A numeric sysctl (4 or 8 bytes; [at] an 8-byte field of a struct of
/// [size] bytes), null when unreadable.
int? _sysctl(String name, {int at = 0, int size = 8}) {
  final f = _sysctlbyname;
  if (f == null) return null;
  final b = _scratch;
  final units = name.codeUnits;
  for (var i = 0; i < units.length; i++) {
    b[512 + i] = units[i];
  }
  b[512 + units.length] = 0;
  for (var i = 0; i < size; i++) {
    b[i] = 0;
  }
  final len = Pointer<IntPtr>.fromAddress(b.address + 1000)..value = size;
  final name0 = Pointer<Uint8>.fromAddress(b.address + 512);
  if (f(name0, b.cast(), len, nullptr, 0) != 0) return null;
  if (size == 8 && len.value == 4) {
    return Pointer<Uint32>.fromAddress(b.address).value;
  }
  return Pointer<Uint64>.fromAddress(b.address + at).value;
}

/// `ri_phys_footprint` of `proc_pid_rusage` (what Activity Monitor shows).
int? _footprint() {
  final f = _rusage;
  if (f == null) return null;
  final b = _scratch;
  if (f(pid, 2, b.cast()) != 0) return null;
  // rusage_info_v2: uuid[16], then u64 user_time, system_time,
  // pkg_idle_wkups, interrupt_wkups, pageins, wired_size, resident_size,
  // phys_footprint.
  return Pointer<Uint64>.fromAddress(b.address + 16 + 7 * 8).value;
}

// --- Windows ---------------------------------------------------------------

final _kernel32 = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
    : null;

/// The low-memory resource notification's handle, made once (the
/// counterpart of macOS's pressure level).
final int _lowMemory = () {
  final create = _kernel32!
      .lookupFunction<IntPtr Function(Int32), int Function(int)>(
        'CreateMemoryResourceNotification',
      );
  return create(0); // LowMemoryResourceNotification
}();

MemoryReadings _windows() {
  final k = _kernel32!;
  final status = k
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalMemoryStatusEx');
  final query = k
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Int32>),
        int Function(int, Pointer<Int32>)
      >('QueryMemoryResourceNotification');
  final process = k.lookupFunction<IntPtr Function(), int Function()>(
    'GetCurrentProcess',
  );
  final counters = k
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('K32GetProcessMemoryInfo');
  final b = _scratch;
  // MEMORYSTATUSEX: dwLength, dwMemoryLoad (u32), then u64 ullTotalPhys,
  // ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual,
  // ullAvailVirtual, ullAvailExtendedVirtual (64 bytes).
  Pointer<Uint32>.fromAddress(b.address).value = 64;
  if (status(b.cast()) == 0) throw StateError('GlobalMemoryStatusEx failed');
  int u64(int at) => Pointer<Uint64>.fromAddress(b.address + at).value;
  final load = Pointer<Uint32>.fromAddress(b.address + 4).value;
  final total = u64(8), avail = u64(16), commitAvail = u64(32);
  // PROCESS_MEMORY_COUNTERS_EX (80 bytes on 64-bit): cb, PageFaultCount,
  // then SIZE_T fields; PrivateUsage at 72.
  final pc = b.address + 128;
  Pointer<Uint32>.fromAddress(pc).value = 80;
  final private = counters(process(), Pointer<Void>.fromAddress(pc), 80) != 0
      ? Pointer<Uint64>.fromAddress(pc + 72).value
      : 0;
  final low = Pointer<Int32>.fromAddress(b.address + 256)..value = 0;
  final lowMemory =
      _lowMemory != 0 && query(_lowMemory, low) != 0 && low.value != 0;
  return MemoryReadings(
    physicalMb: total >> 20,
    processMb: private >> 20,
    availableMb: avail >> 20,
    commitRoomMb: commitAvail >> 20,
    pressure: lowMemory || load >= 90,
  );
}
