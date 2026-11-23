import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'fill_loop.dart';
import 'push_stream.dart';

/// Renders audio on a [RenderIsolate]. The function given to
/// [RenderIsolate.spawn] makes it on the isolate.
abstract interface class IsolateRenderer {
  /// Renders the next [frames] frames of 48 kHz interleaved stereo.
  Float32List render(int frames);

  /// Receives a message sent with [RenderIsolate.send] or to
  /// [RenderIsolate.port].
  void receive(Object? message);

  /// Runs once when the isolate stops, after the fill loop has stopped.
  void stop();
}

/// The render isolate's side, given to the renderer it makes.
class RenderHost {
  RenderHost._(this._reply, this.stream);

  final SendPort _reply;

  /// The output stream the isolate keeps filled. Null when the owner asks
  /// for blocks with [RenderIsolate.render].
  final PcmPushStream? stream;

  FillLoop? _fill;

  /// Reports [message] on [RenderIsolate.problems].
  void problem(String message) => _reply.send(('problem', message));

  /// Seconds of audio the output device has consumed, 0 without a stream.
  double consumed() => stream?.consumed ?? 0;

  /// Frames rendered and pushed into the stream so far.
  int get pushedFrames => _fill?.requestedFrames ?? 0;
}

/// An [IsolateRenderer] on its own isolate. With a [spawn] `stream` (a
/// [PcmPushStream]'s address, opened on the main isolate) the isolate keeps
/// it `lead` seconds ahead by itself, and hitches of the main isolate do not
/// starve it. Without one, [render] requests come back as [blocks].
class RenderIsolate {
  RenderIsolate._(
    this._isolate,
    this.port,
    this._blocks,
    this._problems,
    this._ports,
    this._exited,
  );

  /// Spawns the isolate and makes its renderer there with [make]. [make] is
  /// sent to the isolate, so it may capture only sendable values.
  static Future<RenderIsolate> spawn(
    IsolateRenderer Function(RenderHost host) make, {
    int? stream,
    double lead = 0,
    int block = 960,
  }) async {
    final reply = ReceivePort(), errors = ReceivePort(), exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _main,
      (make, reply.sendPort, stream, lead, block),
      onError: errors.sendPort,
      onExit: exit.sendPort,
    );
    final blocks = StreamController<Float32List>();
    final problems = StreamController<String>.broadcast();
    final ready = Completer<SendPort>();
    reply.listen((m) {
      switch (m) {
        case ('ready', final SendPort p):
          ready.complete(p);
        case ('block', final TransferableTypedData t) when !blocks.isClosed:
          blocks.add(t.materialize().asFloat32List());
        case ('problem', final String s) when !problems.isClosed:
          problems.add(s);
      }
    });
    // A crash in the isolate stops the audio: name it.
    errors.listen((e) {
      if (!problems.isClosed) problems.add('render isolate error: $e');
    });
    return RenderIsolate._(isolate, await ready.future, blocks, problems, [
      reply,
      errors,
      exit,
    ], exit.first);
  }

  final Isolate _isolate;

  /// The isolate's message port. Another isolate sends the renderer's
  /// messages to it.
  final SendPort port;
  final List<ReceivePort> _ports;
  final Future<Object?> _exited;
  final StreamController<Float32List> _blocks;
  final StreamController<String> _problems;

  /// Rendered blocks, in request order.
  Stream<Float32List> get blocks => _blocks.stream;
  Stream<String> get problems => _problems.stream;

  /// Sends [message] to the renderer's [IsolateRenderer.receive].
  void send(Object? message) => port.send(message);

  /// Asks for the next [frames] frames.
  void render(int frames) => port.send(('render', frames));

  /// Stops the isolate's fill loop, waits for it to exit, then closes the
  /// ports and streams: nothing it sent late reaches a closed stream, and
  /// nothing is pushed once this completes.
  Future<void> dispose() async {
    port.send(('stop',));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _exited.timeout(const Duration(seconds: 2), onTimeout: () => null);
    for (final p in _ports) {
      p.close();
    }
    // Not awaited: a close only completes once a listener sees it.
    unawaited(_blocks.close());
    unawaited(_problems.close());
  }

  static void _main(
    (IsolateRenderer Function(RenderHost), SendPort, int?, double, int) args,
  ) {
    final (make, reply, stream, lead, block) = args;
    final host = RenderHost._(
      reply,
      stream == null ? null : PcmPushStream.at(stream),
    );
    final renderer = make(host);
    // Self-filling: push straight into the output ring the main isolate
    // opened (native, process-wide: any isolate reaches it by address).
    FillLoop? fill;
    if (host.stream case final out?) {
      final failed = <String>{};
      fill = host._fill = FillLoop(
        consumed: () => out.consumed,
        render: renderer.render,
        push: out.push,
        lead: lead,
        block: block,
        // Each distinct failure once (a broken voice may throw every block).
        onError: (e, st) {
          if (failed.add('$e')) {
            host.problem('audio render failed (silent block): $e\n$st');
          }
        },
      );
    }
    final port = ReceivePort();
    reply.send(('ready', port.sendPort));
    fill?.start();
    port.listen((m) {
      switch (m) {
        case ('render', final int frames):
          final b = renderer.render(frames);
          reply.send(('block', TransferableTypedData.fromList([b])));
        case ('stop',):
          fill?.stop();
          port.close();
          renderer.stop();
        default:
          renderer.receive(m);
      }
    });
  }
}
