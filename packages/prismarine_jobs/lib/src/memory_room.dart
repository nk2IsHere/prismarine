// Decides if the machine has memory to spare for reads far ahead of their
// use. A read made minutes early holds its parsed data that long. A machine
// short of memory pays for it in paging. The check makes a few system calls
// at most once a second.
import 'dart:io';

import 'memory_readings.dart';
import 'process_memory.dart' show processFootprint;

export 'memory_readings.dart' show MemoryReadings, readMemory;

/// Decides from the memory readings of the OS if reads far ahead fit now.
/// [deep] applies [decide] to the results of [readMemory].
class MemoryRoom {
  MemoryRoom({int? budgetMb, int? minFreeMb, MemoryReadings Function()? read})
    : budgetMb = budgetMb ?? int.tryParse(_env('AHEAD_BUDGET_MB') ?? ''),
      minFreeMb =
          minFreeMb ?? int.tryParse(_env('AHEAD_FREE_MB') ?? '') ?? 2048,
      _read = read ?? readMemory;

  /// The memory of the process past which nothing is read far ahead, compared
  /// with [processFootprint]. Null sets it to 40 % of the memory of the
  /// machine.
  final int? budgetMb;

  /// The memory that the system must have available for reads far ahead.
  /// The cgroup of the process and the commit limit of Windows must have it
  /// too.
  final int minFreeMb;

  final MemoryReadings Function() _read;

  /// `PRISMARINE_AHEAD=deep|short` fixes the answer. Without it the
  /// readings of the OS decide.
  static final _forced = _env('AHEAD');

  /// Reads `PRISMARINE_<name>`, else `MCSM_<name>`.
  static String? _env(String name) =>
      Platform.environment['PRISMARINE_$name'] ??
      Platform.environment['MCSM_$name'];

  bool _deep = false;
  final _clock = Stopwatch();
  MemoryReadings? _last;

  /// The reason of the last answer, for the log.
  String why = 'not checked';

  /// True when reads far ahead fit now. Applies [decide] to the readings of
  /// the OS, read at most once a second.
  bool get deep {
    if (_forced case final f?) {
      why = 'PRISMARINE_AHEAD=$f';
      return f == 'deep';
    }
    if (_clock.isRunning && _clock.elapsedMilliseconds < 1000) return _deep;
    _clock
      ..reset()
      ..start();
    try {
      final now = _read();
      _deep = decide(now, _last);
      _last = now;
    } on Object catch (e) {
      why = 'unreadable: $e';
      _deep = false;
    }
    return _deep;
  }

  /// Returns true when the readings [now] leave room for reads far ahead.
  /// [before] holds the readings of the check before, for paging. Reads far
  /// ahead fit with no memory pressure, no paging since [before], [minFreeMb]
  /// available to the system, the cgroup of the process and the commit limit
  /// where the OS gives them. The process must be within its budget too.
  bool decide(MemoryReadings now, MemoryReadings? before) {
    final budget = budgetMb ?? (now.physicalMb * 2) ~/ 5;
    final paging =
        before != null && now.pagedOutMb > before.pagedOutMb + _pagingMb;
    final short = <String>[
      if (now.pressure) 'pressure',
      if (paging) 'paging',
      if (now.availableMb case final a? when a < minFreeMb) 'available $a MB',
      if (now.cgroupRoomMb case final c? when c < minFreeMb) 'cgroup $c MB',
      if (now.commitRoomMb case final c? when c < minFreeMb) 'commit $c MB',
      if (now.processMb > budget) 'process ${now.processMb} MB',
    ];
    why =
        '${short.isEmpty ? 'room' : short.join(', ')} ($now, budget '
        '$budget MB)';
    return short.isEmpty;
  }

  /// The memory paged out since the check before past which the system
  /// counts as paging. A swap long in use with no growth holds old pages and
  /// is not paging.
  static const _pagingMb = 64;
}
