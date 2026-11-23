// The job system is a bounded pool of one-shot worker isolates. Each job runs
// in its own Isolate.run. Its result returns through Isolate.exit and reaches
// the caller without a copy. Queued jobs start by priority, then in order.
import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'thread_qos.dart';

/// The urgency of a job. A frame needs its job now, a preload soon and a
/// background warm-up eventually.
enum JobPriority { frame, preload, background }

/// The error of a queued job that its token or [JobPool.cancelAll]
/// cancelled.
class JobCancelled implements Exception {
  const JobCancelled(this.label);
  final String label;

  @override
  String toString() => 'JobCancelled($label)';
}

/// Cancels a job that has not started yet.
class JobToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// The time of one finished job in the queue and on its worker.
class JobStats {
  const JobStats(
    this.label,
    this.priority,
    this.waitMs,
    this.runMs, {
    required this.ok,
  });
  final String label;
  final JobPriority priority;
  final double waitMs, runMs;
  final bool ok;
}

abstract class _Queued {
  _Queued(this.priority, this.label, this.token, this.seq);
  final JobPriority priority;
  final String label;
  final JobToken? token;
  final int seq;
  final wait = Stopwatch()..start();

  Future<void> start(void Function(JobStats) stats);
  void fail(Object error);
}

class _Job<T> extends _Queued {
  _Job(this.fn, super.priority, super.label, super.token, super.seq);
  final FutureOr<T> Function() fn;
  final completer = Completer<T>();

  @override
  Future<void> start(void Function(JobStats) stats) async {
    wait.stop();
    final sw = Stopwatch()..start();
    var ok = true;
    try {
      completer.complete(
        await Isolate.run(
          priority == JobPriority.frame ? fn : _background(fn),
          debugName: label,
        ),
      );
    } catch (e, st) {
      ok = false;
      completer.completeError(e, st);
    }
    stats(
      JobStats(
        label,
        priority,
        wait.elapsedMicroseconds / 1000,
        sw.elapsedMicroseconds / 1000,
        ok: ok,
      ),
    );
  }

  @override
  void fail(Object error) => completer.completeError(error);
}

class JobPool {
  JobPool({this.workers = 6, int? backgroundWorkers, this.onStats})
    : backgroundWorkers = backgroundWorkers ?? workers;

  /// The number of jobs that run at once, 6 by default.
  final int workers;

  /// The number of background jobs that run at once, at most. The garbage
  /// of a background job stops every isolate of the group at its
  /// collections, the UI isolate included.
  final int backgroundWorkers;
  final void Function(JobStats)? onStats;

  final _queue = SplayTreeSet<_Queued>((a, b) {
    final p = a.priority.index.compareTo(b.priority.index);
    return p != 0 ? p : a.seq.compareTo(b.seq);
  });
  int _seq = 0, _running = 0, _runningBackground = 0;
  Completer<void>? _idle;

  int get queued => _queue.length;
  int get running => _running;
  int get runningBackground => _runningBackground;

  /// Runs [job] on a worker isolate. [job] and the values that it captures must
  /// be sendable, such as strings, numbers and lists. Open files and ports are
  /// not sendable.
  Future<T> run<T>(
    FutureOr<T> Function() job, {
    JobPriority priority = JobPriority.background,
    String label = '',
    JobToken? token,
  }) {
    if (_closed) return Future.error(JobCancelled(label));
    final j = _Job<T>(job, priority, label, token, _seq++);
    _queue.add(j);
    _pump();
    return j.completer.future;
  }

  bool _closed = false;

  /// True after [close] was called.
  bool get closed => _closed;

  /// Cancels the queue and refuses every later job. Running jobs finish.
  void close() {
    _closed = true;
    _holdTimer?.cancel();
    cancelAll();
  }

  /// Fails every queued job with [JobCancelled]. Running jobs finish.
  void cancelAll() {
    final q = [..._queue];
    _queue.clear();
    for (final j in q) {
      j.fail(JobCancelled(j.label));
    }
    _checkIdle();
  }

  /// Completes when no job is queued or running for one turn of the event
  /// loop. The callbacks of a finished job may queue more jobs.
  Future<void> idle() async {
    do {
      if (_queue.isNotEmpty || _running > 0) {
        await (_idle ??= Completer<void>()).future;
      }
      await Future<void>.delayed(Duration.zero);
    } while (_queue.isNotEmpty || _running > 0);
  }

  // alloc-cold: once per scene switch
  /// Starts no background job for [d] from now. Queued background jobs start
  /// after it. Use it for the first frames of a new scene, which the garbage
  /// of background jobs would stop.
  void holdBackground(Duration d) {
    final until = DateTime.now().add(d);
    if (_heldUntil case final h? when h.isAfter(until)) return;
    _heldUntil = until;
    _holdTimer?.cancel();
    _holdTimer = Timer(d, () {
      _heldUntil = null;
      _holdTimer = null;
      _pump();
    });
  }

  DateTime? _heldUntil;
  Timer? _holdTimer;

  void _pump() {
    while (_running < workers && _queue.isNotEmpty) {
      final j = _queue.first;
      final bg = j.priority == JobPriority.background;
      // Background jobs queue last. Every job left in the queue waits too while
      // they are at their limit or held.
      if (bg &&
          (_runningBackground >= backgroundWorkers || _heldUntil != null)) {
        break;
      }
      _queue.remove(j);
      if (j.token?.cancelled ?? false) {
        j.fail(JobCancelled(j.label));
        continue;
      }
      _running++;
      if (bg) _runningBackground++;
      j.start(onStats ?? (_) {}).whenComplete(() {
        _running--;
        if (bg) _runningBackground--;
        _pump();
        _checkIdle();
      });
    }
    _checkIdle();
  }

  void _checkIdle() {
    if (_queue.isEmpty && _running == 0) {
      final c = _idle;
      _idle = null;
      c?.complete();
    }
  }
}

/// Returns [fn] wrapped to run in the background role of thread_roles.dart.
/// The role of the thread is restored after the synchronous part of [fn],
/// since the threads of the pool serve other isolates next.
FutureOr<T> Function() _background<T>(FutureOr<T> Function() fn) => () {
  final prev = lowerThreadQos();
  try {
    return fn();
  } finally {
    restoreThreadQos(prev);
  }
};
