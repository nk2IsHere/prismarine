// The memory that the process holds, read without allocation after the first
// call. macOS reads proc_pid_rusage, Linux reads /proc/self/status through a
// kept file descriptor and Windows calls K32GetProcessMemoryInfo.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'thread_linux.dart' show nativeBlock;

/// Returns the memory that the process holds in bytes, or null when the OS
/// gives no reading.
///
/// It is the physical footprint on macOS, the figure that Activity Monitor
/// shows, with compressed and swapped pages and the memory of the GPU. On
/// Linux it is the resident anonymous memory plus the swapped memory, the
/// `RssAnon` and `VmSwap` lines of `/proc/self/status`. On Windows it is the
/// private bytes, `PrivateUsage` of the process memory counters.
int? processFootprint() {
  if (Platform.isMacOS) return _mac();
  if (Platform.isLinux || Platform.isAndroid) return _linux();
  if (Platform.isWindows) return _windows();
  return null;
}

/// Returns the sum of the `RssAnon` and `VmSwap` lines of the first [length]
/// bytes of [status], the text of `/proc/<pid>/status`, in bytes. Returns
/// null when the text has no `RssAnon` line.
int? footprintOfProcStatus(Uint8List status, int length) {
  final anon = _kbOfLine(status, length, _rssAnon);
  if (anon == null) return null;
  return (anon + (_kbOfLine(status, length, _vmSwap) ?? 0)) * 1024;
}

const _rssAnon = [82, 115, 115, 65, 110, 111, 110, 58]; // RssAnon:
const _vmSwap = [86, 109, 83, 119, 97, 112, 58]; // VmSwap:

// Returns the number of the line that starts with [key], in kB, or null.
int? _kbOfLine(Uint8List b, int length, List<int> key) {
  var start = 0;
  while (start < length) {
    var match = start + key.length <= length;
    for (var k = 0; match && k < key.length; k++) {
      if (b[start + k] != key[k]) match = false;
    }
    if (match) {
      var i = start + key.length;
      while (i < length && (b[i] == 32 || b[i] == 9)) {
        i++;
      }
      var v = 0, digits = 0;
      while (i < length && b[i] >= 48 && b[i] <= 57) {
        v = v * 10 + b[i] - 48;
        i++;
        digits++;
      }
      return digits == 0 ? null : v;
    }
    while (start < length && b[start] != 10) {
      start++;
    }
    start++;
  }
  return null;
}

// --- macOS -----------------------------------------------------------------

final _rusage = Platform.isMacOS
    ? DynamicLibrary.process().lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('proc_pid_rusage')
    : null;
Pointer<Uint8>? _macBuf;

int? _mac() {
  final b = _macBuf ??= nativeBlock(512);
  if (_rusage!(pid, 2, b.cast()) != 0) return null; // RUSAGE_INFO_V2
  return footprintOfRusage(b);
}

/// Returns `ri_phys_footprint` of the `rusage_info_v2` at [info]. The struct
/// has uuid[16] and then the u64 fields user_time, system_time,
/// pkg_idle_wkups, interrupt_wkups, pageins, wired_size, resident_size and
/// phys_footprint.
int footprintOfRusage(Pointer<Uint8> info) =>
    Pointer<Uint64>.fromAddress(info.address + 16 + 7 * 8).value;

// --- Linux -----------------------------------------------------------------

const _statusBytes = 4096;
Pointer<Uint8>? _statusBuf;
Uint8List? _status;
int _statusFd = -1;

final _pread = Platform.isLinux || Platform.isAndroid
    ? DynamicLibrary.process().lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int64),
        int Function(int, Pointer<Uint8>, int, int)
      >('pread')
    : null;

int? _linux() {
  final buf = _statusBuf ??= nativeBlock(_statusBytes);
  if (_statusFd < 0) {
    final open = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, int)
        >('open');
    const path = '/proc/self/status';
    for (var i = 0; i < path.length; i++) {
      buf[i] = path.codeUnitAt(i);
    }
    buf[path.length] = 0;
    _statusFd = open(buf, 0); // O_RDONLY
    if (_statusFd < 0) return null;
  }
  // The kernel builds the text again for each read from offset 0.
  final n = _pread!(_statusFd, buf, _statusBytes, 0);
  if (n <= 0) return null;
  return footprintOfProcStatus(_status ??= buf.asTypedList(_statusBytes), n);
}

// --- Windows ---------------------------------------------------------------

Pointer<Uint8>? _winBuf;
int Function()? _currentProcess;
int Function(int, Pointer<Uint8>, int)? _counters;

int? _windows() {
  if (_counters == null) {
    final k = DynamicLibrary.open('kernel32.dll');
    _currentProcess = k.lookupFunction<IntPtr Function(), int Function()>(
      'GetCurrentProcess',
    );
    _counters = k
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
          int Function(int, Pointer<Uint8>, int)
        >('K32GetProcessMemoryInfo');
  }
  final b = _winBuf ??= nativeBlock(processCountersBytes);
  Pointer<Uint32>.fromAddress(b.address).value = processCountersBytes;
  if (_counters!(_currentProcess!(), b, processCountersBytes) == 0) {
    return null;
  }
  return privateUsageOfCounters(b);
}

/// The size of `PROCESS_MEMORY_COUNTERS_EX` on 64-bit Windows.
const processCountersBytes = 80;

/// Returns `PrivateUsage` of the `PROCESS_MEMORY_COUNTERS_EX` at [counters].
/// The struct holds the u32 fields cb and PageFaultCount and then nine
/// SIZE_T fields, with PrivateUsage last at offset 72 on 64-bit.
int privateUsageOfCounters(Pointer<Uint8> counters) =>
    Pointer<Uint64>.fromAddress(counters.address + 72).value;
