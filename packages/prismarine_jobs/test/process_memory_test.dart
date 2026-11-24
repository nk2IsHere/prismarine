import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_jobs/src/process_memory.dart';
import 'package:test/test.dart';

void main() {
  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  test('Linux status text gives RssAnon plus VmSwap', () {
    final t = text(
      'Name:\tdart\nVmRSS:\t  900000 kB\nRssAnon:\t  512000 kB\n'
      'RssFile:\t  380000 kB\nVmSwap:\t    2048 kB\nThreads:\t12\n',
    );
    expect(footprintOfProcStatus(t, t.length), (512000 + 2048) * 1024);
  });

  test('Linux status text without swap or cut short', () {
    final t = text('RssAnon:\t  1000 kB\nRssFile:\t 5 kB\n');
    expect(footprintOfProcStatus(t, t.length), 1000 * 1024);
    // Only the first bytes count, as after a short read.
    expect(footprintOfProcStatus(t, 9), isNull);
    expect(footprintOfProcStatus(text('VmRSS:\t 7 kB\n'), 13), isNull);
  });

  test('Linux status text ignores a key in the middle of a line', () {
    final t = text('Note: RssAnon: 5 kB\nRssAnon:\t 6 kB\n');
    expect(footprintOfProcStatus(t, t.length), 6 * 1024);
  });

  test('macOS rusage_info_v2 gives phys_footprint at byte 72', () {
    final b = calloc<Uint8>(512);
    Pointer<Uint64>.fromAddress(b.address + 64).value = 111; // resident_size
    Pointer<Uint64>.fromAddress(b.address + 72).value = 222;
    expect(footprintOfRusage(b), 222);
    calloc.free(b);
  });

  test('Windows PROCESS_MEMORY_COUNTERS_EX gives PrivateUsage at byte 72', () {
    final b = calloc<Uint8>(processCountersBytes);
    Pointer<Uint64>.fromAddress(b.address + 64).value = 1; // PeakPagefileUsage
    Pointer<Uint64>.fromAddress(b.address + 72).value = 333;
    expect(privateUsageOfCounters(b), 333);
    calloc.free(b);
  });

  test('this process has a footprint between 1 MB and 64 GB', () {
    final f = processFootprint();
    if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      expect(f, isNull);
      return;
    }
    expect(f, inInclusiveRange(1 << 20, 64 << 30));
    expect(processFootprint(), inInclusiveRange(1 << 20, 64 << 30));
  });
}
