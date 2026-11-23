// Whether the machine has memory to spare for reads far ahead of their
// use: a read made minutes early holds its parsed data that long, which a
// machine short of memory pays for in paging on every switch (a 1.5 GB
// scope: a coming scene's chores and clips read at the scene before's
// open made its holds longer). A few system calls, at most once a second.
import 'dart:io';

import 'memory_readings.dart';

export 'memory_readings.dart' show MemoryReadings, readMemory;

/// What the OS says about memory now: room for reads far ahead ([deep]) or
/// not, from [readMemory] (macOS, Linux, Windows) through [decide].
class MemoryRoom {
  MemoryRoom({int? budgetMb, int? minFreeMb, MemoryReadings Function()? read})
    : budgetMb =
          budgetMb ??
          int.tryParse(Platform.environment['MCSM_AHEAD_BUDGET_MB'] ?? ''),
      minFreeMb =
          minFreeMb ??
          int.tryParse(Platform.environment['MCSM_AHEAD_FREE_MB'] ?? '') ??
          2048,
      _read = read ?? readMemory;

  /// The process's own memory (macOS: its footprint; Linux: its resident
  /// set; Windows: its private bytes) past which nothing is read far ahead;
  /// null: 40 % of the machine's memory.
  final int? budgetMb;

  /// The memory the system (and the process's cgroup, or the Windows commit
  /// limit) must have available for reads far ahead.
  final int minFreeMb;

  final MemoryReadings Function() _read;

  /// `MCSM_AHEAD=deep|short` fixes the answer (A/B runs); else the OS's.
  static final _forced = Platform.environment['MCSM_AHEAD'];

  bool _deep = false;
  final _clock = Stopwatch();
  MemoryReadings? _last;

  /// Why the last check answered as it did, for the log.
  String why = 'not checked';

  /// Whether reads far ahead fit now ([decide] over the OS's readings,
  /// read at most once a second).
  bool get deep {
    if (_forced case final f?) {
      why = 'MCSM_AHEAD=$f';
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

  /// The decision over [now] (and the readings a check before, [before],
  /// for paging): no memory pressure, no paging since then, [minFreeMb]
  /// available to the system, the process's cgroup and the commit limit
  /// (those the OS gives), and the process within its budget.
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

  /// Paged out since the check before past which the system counts as
  /// paging (a swap long in use with no growth is old pages, not paging).
  static const _pagingMb = 64;
}
