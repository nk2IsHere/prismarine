part of 'frame_runner.dart';

/// The most timed parts of a frame, the part before the first timed pass
/// included.
const maxTimedParts = 16;

/// The timed parts of a frame (FrameRunner.timedParts). Each part is recorded
/// into a command buffer of its own. The buffers are submitted in order after
/// the last one is recorded. The time from the completion of one buffer to the
/// completion of the next is the GPU time of the part.
final class _Timing {
  _Timing(this._clock) {
    for (var i = 0; i < maxTimedParts; i++) {
      _done.add((_) => _doneAt[i] = _clock.elapsedMicroseconds);
    }
  }

  final Stopwatch _clock;
  final _pending = List<gpu.CommandBuffer?>.filled(maxTimedParts, null);
  final _doneAt = Int64List(maxTimedParts);
  final _done = <gpu.CompletionCallback>[];
  List<String> _names = const [];
  int _count = 0;

  /// Starts the parts of a run with the passes [names].
  void begin(List<String> names) {
    _names = names;
    _count = 0;
  }

  /// Returns true when the pass [name] starts a part.
  bool starts(String name) {
    if (_count + 1 >= maxTimedParts) return false;
    final n = _names;
    for (var i = 0; i < n.length; i++) {
      if (n[i] == name) return true;
    }
    return false;
  }

  /// Keeps [cb] for the submit at the end of the run. Returns the command
  /// buffer of the next part.
  gpu.CommandBuffer cut(gpu.CommandBuffer cb) {
    _pending[_count++] = cb;
    return gpu.gpuContext.createCommandBuffer();
  }

  /// Submits the kept command buffers in order.
  void submit() {
    for (var i = 0; i < _count; i++) {
      gpuSubmitted();
      _pending[i]!.submit(completionCallback: _done[i]);
      _pending[i] = null;
    }
  }

  /// The cuts of the run so far. A run has one part more.
  int get cuts => _count;

  /// Writes the GPU time in ms of each of the [cuts] + 1 parts of a frame
  /// into [out], from [from] to [last], both on the clock of the runner in
  /// µs. Clears the rest of [out].
  void read(Float64List out, int cuts, int from, int last) {
    var at = from;
    for (var i = 0; i <= cuts; i++) {
      final end = i < cuts ? _doneAt[i] : last;
      out[i] = end > at ? (end - at) / 1000 : 0;
      if (end > at) at = end;
    }
    for (var i = cuts + 1; i < out.length; i++) {
      out[i] = 0;
    }
  }
}
