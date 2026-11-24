// Reads the frames that the window really shows, after the compositing of
// Flutter. The glitch catcher checks these frames as it checks those of the
// history ring. A glitch in the compositing of Flutter shows only here.
//
// Each UI frame the source of the platform takes what the window shows now
// and passes it to a worker isolate, which reads a 640-wide copy. The
// sources are the IOSurface of the window on macOS, the X11 window of GTK on
// Linux and the client area of the window on Windows.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'window_surface_mac.dart';
import 'window_surface_windows.dart';
import 'window_surface_x11.dart';

/// The arguments of a worker isolate of a [SurfaceSource]. They are the port
/// for the port of the worker, the port for frames and notes, the width of a
/// copy and [SurfaceSource.workerArg].
typedef WorkerArgs = (SendPort, SendPort, int, Object?);

/// A way to read the window of one platform.
abstract interface class SurfaceSource {
  /// The entry of the worker isolate. It sends its own port on the first
  /// port of its arguments and reads each message of [take]. A null message
  /// ends it.
  void Function(WorkerArgs) get worker;

  /// A value for the worker that is known at the start.
  Object? get workerArg;

  /// Returns the message that makes the worker read the shown picture, or
  /// null when the window shows nothing that can be read.
  Object? take();

  /// Describes the windows for a log line when [take] returns null.
  String describe();
}

/// Sends the copies of a worker to the UI isolate. A copy that equals the
/// last one is not sent, as is the case without a new present since the last
/// take.
class FrameSender {
  FrameSender(this._out, this._width);

  final SendPort _out;
  final int _width;
  int _lastSum = -1, _notes = 0;

  /// Sends [rgba], [height] rows of the width of the copy, unless [sum]
  /// equals the sum of the last copy.
  void send(Uint8List rgba, int height, int sum) {
    if (sum == _lastSum) return;
    _lastSum = sum;
    _out.send([
      TransferableTypedData.fromList([rgba]),
      _width,
      height,
    ]);
  }

  /// Sends [text] to the note of the reader. Only the first two notes are
  /// sent.
  void note(String text) {
    if (_notes++ < 2) _out.send(text);
  }
}

/// Takes the shown picture of the window each UI frame and reads it on a
/// worker.
class WindowSurfaceReader {
  WindowSurfaceReader._(this._send, this._source);

  /// Returns a reader that passes each new RGBA frame of [width] to
  /// [onFrame] on the UI isolate. Returns null on a system without a source,
  /// when the UI isolate is not on the main thread or when the window cannot
  /// be found.
  static Future<WindowSurfaceReader?> start(
    void Function(Uint8List rgba, int width, int height) onFrame, {
    int width = 640,
  }) async {
    final SurfaceSource? source = Platform.isMacOS
        ? MacSurfaceSource.open()
        : Platform.isLinux
        ? X11SurfaceSource.open()
        : Platform.isWindows
        ? WindowsSurfaceSource.open()
        : null;
    if (source == null) return null;
    final port = ReceivePort();
    final ready = ReceivePort();
    await Isolate.spawn(source.worker, (
      ready.sendPort,
      port.sendPort,
      width,
      source.workerArg,
    ));
    final send = await ready.first as SendPort;
    late final WindowSurfaceReader reader;
    port.listen((m) {
      if (m is String) {
        reader.note = '${reader.note ?? ''} $m';
        return;
      }
      final l = m as List;
      onFrame(
        (l[0] as TransferableTypedData).materialize().asUint8List(),
        l[1] as int,
        l[2] as int,
      );
    });
    return reader = WindowSurfaceReader._(send, source);
  }

  final SendPort _send;
  final SurfaceSource _source;
  int taken = 0, missed = 0;
  String? note;

  /// Passes what the window shows now to the worker, which reads it once the
  /// GPU is done with it. Call it once per UI frame.
  void take() {
    final m = _source.take();
    if (m == null) {
      if (missed++ == 0) note = _source.describe();
      return;
    }
    taken++;
    _send.send(m);
  }

  void close() => _send.send(null);
}
