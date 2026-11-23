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

/// The side of the render isolate, given to the renderer that it makes.
class RenderHost {
  RenderHost._(this._reply, this.stream);

  final SendPort _reply;

  /// The output stream the isolate keeps filled. Null when the owner asks
  /// for blocks with [RenderIsolate.render].
  final PcmPushStream? stream;

  FillLoop? _fill;

  /// Reports [message] on [RenderIsolate.problems].
  void problem(String message) => _reply.send(('problem', message));

  /// Returns the seconds of audio that the output device has consumed, 0
  /// without a stream.
  double consumed() => stream?.consumed ?? 0;

  /// The number of frames rendered and pushed into the stream so far.
  int get pushedFrames => _fill?.requestedFrames ?? 0;
}

/// An [IsolateRenderer] on its own isolate. With the `stream` of [spawn],
/// the address of a [PcmPushStream] opened on the main isolate, the isolate
/// keeps the stream `lead` seconds ahead by itself. Hitches of the main
/// isolate then do not starve it. Without a stream, [render] requests come
/// back as [blocks].
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
  /// sent to the isolate and may capture only sendable values.
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
    // A crash in the isolate stops the audio and is reported.
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

  /// The rendered blocks in request order.
  Stream<Float32List> get blocks => _blocks.stream;
  Stream<String> get problems => _problems.stream;

  /// Sends [message] to the renderer's [IsolateRenderer.receive].
  void send(Object? message) => port.send(message);

  /// Asks for the next [frames] frames.
  void render(int frames) => port.send(('render', frames));

  /// Stops the fill loop of the isolate, waits for it to exit and then
  /// closes the ports and streams. Nothing that it sent late reaches a
  /// closed stream. Nothing is pushed once this completes.
  Future<void> dispose() async {
    port.send(('stop',));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _exited.timeout(const Duration(seconds: 2), onTimeout: () => null);
    for (final p in _ports) {
      p.close();
    }
    // Not awaited, since a close only completes once a listener sees it.
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
    // The isolate fills by itself and pushes straight into the output ring that
    // the main isolate opened. The ring is native and process-wide. Any isolate
    // reaches it by address.
    FillLoop? fill;
    if (host.stream case final out?) {
      final failed = <String>{};
      fill = host._fill = FillLoop(
        consumed: () => out.consumed,
        render: renderer.render,
        push: out.push,
        lead: lead,
        block: block,
        // Each distinct failure is reported once, since a broken source may
        // throw in every block.
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
