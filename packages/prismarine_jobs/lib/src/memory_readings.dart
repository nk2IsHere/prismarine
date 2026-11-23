// The memory readings of the OS for MemoryRoom. macOS reads sysctl and
// proc_pid_rusage. Linux reads /proc and the cgroup v2 files. Windows calls
// GlobalMemoryStatusEx and K32GetProcessMemoryInfo of kernel32 and uses a
// low-memory resource notification.
import 'dart:ffi';
import 'dart:io';

/// One reading of the memory of the machine, in MB.
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

  /// The physical memory of the machine.
  final int physicalMb;

  /// The memory of the process. It is the footprint on macOS, the resident
  /// set on Linux and the private bytes on Windows.
  final int processMb;

  /// The memory available to the system without paging, `MemAvailable` on
  /// Linux and `ullAvailPhys` on Windows. Null on macOS, whose free pages say
  /// little next to its file cache.
  final int? availableMb;

  /// The room under the cgroup v2 memory limit of the process on Linux, or
  /// null without a limit. It is the limit less the memory that the cgroup
  /// holds, without the reclaimable file pages.
  final int? cgroupRoomMb;

  /// The room under the commit limit, `ullAvailPageFile` on Windows.
  final int? commitRoomMb;

  /// The memory paged out so far, a running total that is compared between
  /// readings. It is `pswpout` on Linux, the use of the swap file on macOS
  /// and 0 where it is unknown.
  final int pagedOutMb;

  /// True when the OS reports that memory is short. It is a pressure level
  /// above normal on macOS, and the low-memory resource notification or a
  /// memory load of 90 % on Windows.
  final bool pressure;

  @override
  String toString() =>
      'physical $physicalMb, process $processMb'
      '${availableMb == null ? '' : ', available $availableMb'}'
      '${cgroupRoomMb == null ? '' : ', cgroup room $cgroupRoomMb'}'
      '${commitRoomMb == null ? '' : ', commit room $commitRoomMb'}'
      ', paged out $pagedOutMb${pressure ? ', pressure' : ''}';
}

/// Returns the readings of this machine now. Throws on an OS without
/// readings.
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
    // pswpout counts pages of 4 KB.
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

/// Returns the tightest room under a cgroup v2 memory limit along the cgroup
/// path of the process, or null without a limit.
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
  // kern.memorystatus_vm_pressure_level is 1 for normal, 2 for warning and 4
  // for critical.
  final level = _sysctl('kern.memorystatus_vm_pressure_level') ?? 4;
  return MemoryReadings(
    physicalMb: (_sysctl('hw.memsize') ?? 0) >> 20,
    processMb: (_footprint() ?? 0) >> 20,
    // vm.swapusage is an xsw_usage of the u64 fields total, avail and used.
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

/// 1 KB of scratch for the calls, kept for the life of the isolate.
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

/// Returns the numeric sysctl [name] of 4 or 8 bytes, or null when it is
/// unreadable. [at] selects an 8-byte field of a struct of [size] bytes.
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

/// Returns the `ri_phys_footprint` of `proc_pid_rusage`, the figure that
/// Activity Monitor shows.
int? _footprint() {
  final f = _rusage;
  if (f == null) return null;
  final b = _scratch;
  if (f(pid, 2, b.cast()) != 0) return null;
  // rusage_info_v2 has uuid[16] and then the u64 fields user_time,
  // system_time, pkg_idle_wkups, interrupt_wkups, pageins, wired_size,
  // resident_size and phys_footprint.
  return Pointer<Uint64>.fromAddress(b.address + 16 + 7 * 8).value;
}

// --- Windows ---------------------------------------------------------------

final _kernel32 = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
    : null;

/// The handle of the low-memory resource notification, made once.
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
  // MEMORYSTATUSEX has 64 bytes. It holds the u32 fields dwLength and
  // dwMemoryLoad and then the u64 fields ullTotalPhys, ullAvailPhys,
  // ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual and
  // ullAvailExtendedVirtual.
  Pointer<Uint32>.fromAddress(b.address).value = 64;
  if (status(b.cast()) == 0) throw StateError('GlobalMemoryStatusEx failed');
  int u64(int at) => Pointer<Uint64>.fromAddress(b.address + at).value;
  final load = Pointer<Uint32>.fromAddress(b.address + 4).value;
  final total = u64(8), avail = u64(16), commitAvail = u64(32);
  // PROCESS_MEMORY_COUNTERS_EX has 80 bytes on 64-bit. It holds cb and
  // PageFaultCount and then SIZE_T fields, with PrivateUsage at 72.
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
