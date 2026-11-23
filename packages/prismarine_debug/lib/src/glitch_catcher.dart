// The glitch catcher reads back every frame that the history ring keeps and
// compares it with the frames shown before and after it. A kept frame is the
// image that the window was given, the 3D frame copied on the GPU right after
// it was drawn with the UI scenes blended over it. A frame with a bright
// patch that neither neighbour has, while the neighbours agree with each
// other, is a one-frame artefact, such as the triangles of a GPU race. The
// three frames and a mask of the flagged pixels go to `<run>/caught/`, with
// one line each in `caught.jsonl`. The catcher keeps what was actually
// drawn, GPU races included.
//
// It is off by default. It reads back one 640 × 360 frame through the raster
// thread every frame.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_assets/prismarine_assets.dart' show encodePng;

import 'frame_history.dart';
import 'issue.dart';

class GlitchCatcher {
  GlitchCatcher(this.dir, {this.log});

  /// The folder of the caught frames, `<run>/caught`.
  final String dir;
  final void Function(String line)? log;

  /// The maximum number of read-backs in flight. A frame past it is not
  /// checked and its neighbours are not checked against it.
  static const maxInFlight = 4;

  int _inFlight = 0;
  int read = 0, dropped = 0, flagged = 0;
  SendPort? _worker;
  final _ready = Completer<SendPort>();
  ReceivePort? _port;
  final _pending = <Object?>[];

  void _start() {
    if (_port != null) return;
    Directory(dir).createSync(recursive: true);
    final port = _port = ReceivePort();
    port.listen((m) {
      if (m is SendPort) {
        _worker = m;
        _ready.complete(m);
        for (final p in _pending) {
          m.send(p);
        }
        _pending.clear();
      } else if (m is Map) {
        flagged++;
        log?.call(
          'catch: ${m['kind']} artefact (${m['stream']}) near frame ${m['frame']} '
          '(t ${m['t']}, ${m['count']} px, largest patch ${m['blob']} px, '
          'box ${m['box']})'
          '${m['png'] == null ? '' : ': ${m['png']}'}',
        );
      }
    });
    Isolate.spawn(_catcherMain, (port.sendPort, dir));
  }

  void _send(Object? message) {
    final w = _worker;
    if (w == null) {
      _pending.add(message);
    } else {
      w.send(message);
    }
  }

  /// Reads [frame] back and passes it to the checker with [seq] and [meta].
  /// Set it as [FrameHistory.onFrameDone].
  void frameDone(int seq, gpu.Texture frame, HistoryMeta meta) {
    _start();
    if (_inFlight >= maxInFlight) {
      dropped++;
      _send(['gap', 'ring', seq]);
      return;
    }
    _inFlight++;
    final image = frame.asImage();
    () async {
      try {
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final (w, h) = (image.width, image.height);
        if (raw == null) {
          _send(['gap', 'ring', seq]);
          return;
        }
        read++;
        _last = meta;
        _send([
          'frame',
          'ring',
          seq,
          meta.frame,
          meta.time,
          meta.wall,
          meta.scene,
          w,
          h,
          TransferableTypedData.fromList([raw.buffer.asUint8List()]),
        ]);
      } finally {
        image.dispose();
        _inFlight--;
      }
    }();
  }

  HistoryMeta? _last;
  static final (double, double)? _saveSpan =
      switch ((Platform.environment['PRISMARINE_CATCH_SAVE'] ??
              Platform.environment['MCSM_CATCH_SAVE'])
          ?.split(':')) {
        [final a, final b] => (double.parse(a), double.parse(b)),
        _ => null,
      };
  int _windowSeq = 0;
  int windowFrames = 0;

  /// Checks the frame [rgba] of [width] by [height] that the window showed
  /// against the window frames before and after it. The frame comes from
  /// WindowSurfaceReader and carries the time of the newest history frame.
  void windowFrame(Uint8List rgba, int width, int height) {
    _start();
    windowFrames++;
    final m = _last;
    // With PRISMARINE_CATCH_SAVE=<t0>:<t1> every window frame in that stretch
    // of game time is kept as well in window_all/, to step through a moment
    // frame by frame.
    if (_saveSpan case (final t0, final t1)? when m != null) {
      if (m.time >= t0 && m.time <= t1) {
        final path =
            '$dir/window_all/${_windowSeq.toString().padLeft(6, '0')}'
            '_t${m.time.toStringAsFixed(3)}.png';
        final bytes = TransferableTypedData.fromList([rgba]);
        Isolate.run(() {
          File(path)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(
              encodePng(
                width,
                height,
                bytes.materialize().asUint8List(),
                alpha: false,
                level: 1,
              ),
            );
        });
      }
    }
    _send([
      'frame',
      'window',
      _windowSeq++,
      m?.frame ?? -1,
      m?.time ?? -1.0,
      m?.wall ?? -1.0,
      m?.scene,
      width,
      height,
      TransferableTypedData.fromList([rgba]),
    ]);
  }

  /// The summary line of the run.
  String get summary =>
      'catch: $read history frames read back, $dropped not checked '
      '(read-backs busy), $windowFrames window frames read, $flagged '
      'flagged${flagged > 0 ? ' ($dir)' : ''}';

  void close() {
    if (_worker case final w?) w.send(null);
    _port?.close();
  }
}

/// Writes the newest [count] frames of the history, the images that the
/// window was given, into [dir] as `shown_<k>_f<frame>.png`, where k = 0 is
/// the newest. These frames show a GPU glitch that a re-rendered screenshot
/// does not show.
Future<void> writeShownFrames(
  FrameHistory history,
  String dir, {
  int count = 8,
}) async {
  final n = history.length < count ? history.length : count;
  for (var k = 0; k < n; k++) {
    final meta = history.metaAt(k);
    final image = history.imageAt(k);
    try {
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) continue;
      final (w, h) = (image.width, image.height);
      final bytes = TransferableTypedData.fromList([raw.buffer.asUint8List()]);
      final path = '$dir/shown_${k}_f${meta.frame}.png';
      await Isolate.run(() {
        File(path).writeAsBytesSync(
          encodePng(
            w,
            h,
            bytes.materialize().asUint8List(),
            alpha: false,
            level: 1,
          ),
        );
      });
    } finally {
      image.dispose();
    }
  }
}

// --- The checker (its own isolate) -------------------------------------------

/// A shown frame as the checker holds it.
class _Frame {
  _Frame(
    this.seq,
    this.frame,
    this.t,
    this.wall,
    this.scene,
    this.w,
    this.h,
    this.rgba,
  );
  final int seq, frame;
  final double t, wall;
  final String? scene;
  final int w, h;
  final Uint8List rgba;
  Uint8List? _luma;

  Uint8List get luma {
    if (_luma case final l?) return l;
    final l = Uint8List(w * h);
    for (var i = 0, j = 0; i < l.length; i++, j += 4) {
      l[i] = (77 * rgba[j] + 150 * rgba[j + 1] + 29 * rgba[j + 2]) >> 8;
    }
    return _luma = l;
  }
}

/// The thresholds for a pixel of a one-frame bright artefact. The pixel is
/// bright in the frame and [rise] levels above every pixel of both
/// neighbours within [reach] pixels. A thing that moved a little between the
/// frames, such as a rim light on a swinging arm, is then not flagged.
class GlitchThresholds {
  const GlitchThresholds({
    this.bright = 150,
    this.rise = 60,
    this.reach = 8,
    this.grey = 64,
    this.minBlob = 60,
  });
  final int bright, rise, reach;

  /// The largest distance from grey of a flagged pixel, the max − min of its
  /// R, G and B. The artefacts are white and a saturated rim light on a
  /// moving arm is not.
  final int grey;

  /// The pixels that the largest connected patch of flagged pixels needs at
  /// the 640 × 360 of the ring. A stretched triangle is one patch. Sparkles,
  /// embers and mouth shapes that change for a frame are many small ones.
  final int minBlob;
}

/// Returns the pixels of [cur] that are a one-frame bright artefact against
/// [prev] and [next]. All three are luma of one byte per pixel and of the
/// same size. Returns the count, the bounding box (x0, y0, x1, y1) and a mask
/// that is 255 where flagged.
({int count, List<int> box, Uint8List mask}) brightTransient(
  Uint8List prev,
  Uint8List cur,
  Uint8List next,
  int w, {
  Uint8List? rgba,
  GlitchThresholds th = const GlitchThresholds(),
}) {
  final h = cur.length ~/ w;
  // The brightest pixel of either neighbour within [reach], as a max filter
  // over rows and then columns.
  final both = Uint8List(cur.length);
  for (var i = 0; i < both.length; i++) {
    both[i] = prev[i] > next[i] ? prev[i] : next[i];
  }
  final rows = Uint8List(cur.length);
  final r = th.reach;
  for (var y = 0; y < h; y++) {
    final o = y * w;
    for (var x = 0; x < w; x++) {
      var m = 0;
      final a = x - r < 0 ? 0 : x - r, b = x + r >= w ? w - 1 : x + r;
      for (var k = a; k <= b; k++) {
        final v = both[o + k];
        if (v > m) m = v;
      }
      rows[o + x] = m;
    }
  }
  final mask = Uint8List(cur.length);
  var count = 0;
  var x0 = w, y0 = 1 << 30, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    final a = y - r < 0 ? 0 : y - r, b = y + r >= h ? h - 1 : y + r;
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final c = cur[i];
      if (c < th.bright) continue;
      var m = 0;
      for (var k = a; k <= b; k++) {
        final v = rows[k * w + x];
        if (v > m) m = v;
      }
      if (c - m < th.rise) continue;
      if (rgba != null) {
        final r0 = rgba[i * 4], g0 = rgba[i * 4 + 1], b0 = rgba[i * 4 + 2];
        final hi = r0 > g0 ? (r0 > b0 ? r0 : b0) : (g0 > b0 ? g0 : b0);
        final lo = r0 < g0 ? (r0 < b0 ? r0 : b0) : (g0 < b0 ? g0 : b0);
        if (hi - lo > th.grey) continue;
      }
      mask[i] = 255;
      count++;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return (
    count: count,
    box: count == 0 ? const [] : [x0, y0, x1, y1],
    mask: mask,
  );
}

/// Returns the size of the largest 4-connected patch of set pixels in [mask].
int largestBlob(Uint8List mask, int w) {
  final seen = Uint8List(mask.length);
  final stack = <int>[];
  var best = 0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0 || seen[i] != 0) continue;
    var size = 0;
    seen[i] = 1;
    stack.add(i);
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      size++;
      final x = k % w;
      for (final j in [if (x > 0) k - 1, if (x < w - 1) k + 1, k - w, k + w]) {
        if (j < 0 || j >= mask.length || mask[j] == 0 || seen[j] != 0) {
          continue;
        }
        seen[j] = 1;
        stack.add(j);
      }
    }
    if (size > best) best = size;
  }
  return best;
}

void _catcherMain((SendPort, String) args) {
  final (reply, dir) = args;
  final port = ReceivePort();
  reply.send(port.sendPort);
  final windows = {'ring': <_Frame>[], 'window': <_Frame>[]};
  final jsonl = File('$dir/caught.jsonl');
  // Every large catch is kept. Small ones, such as mouth shapes and sparks,
  // are kept only up to a few to keep the folder of a long run small.
  var saved = 0, savedSmall = 0;
  const maxSaved = 300, maxSmall = 40, large = 150;
  port.listen((m) {
    if (m == null) {
      port.close();
      return;
    }
    final msg = m as List;
    final stream = msg[1] as String;
    final window = windows[stream]!;
    if (msg[0] == 'gap') {
      window.clear();
      return;
    }
    final f = _Frame(
      msg[2] as int,
      msg[3] as int,
      (msg[4] as num).toDouble(),
      (msg[5] as num).toDouble(),
      msg[6] as String?,
      msg[7] as int,
      msg[8] as int,
      (msg[9] as TransferableTypedData).materialize().asUint8List(),
    );
    // Read-backs can finish out of order. The window stays in seq order and
    // restarts at a hole.
    if (window.isNotEmpty && f.seq != window.last.seq + 1) {
      if (f.seq <= window.last.seq) return;
      window.clear();
    }
    window.add(f);
    if (window.length > 3) window.removeAt(0);
    if (window.length < 3) return;
    final [p, c, n] = window;
    if (p.w != c.w || n.w != c.w || p.h != c.h || n.h != c.h) return;
    final r = brightTransient(p.luma, c.luma, n.luma, c.w, rgba: c.rgba);
    if (r.count < const GlitchThresholds().minBlob) return;
    final blob = largestBlob(r.mask, c.w);
    if (blob < const GlitchThresholds().minBlob) return;
    final out =
        '$dir/${stream == 'window' ? 'window_' : ''}'
        '${c.seq.toString().padLeft(6, '0')}_f${c.frame}_${blob}px.png';
    final keep = saved < maxSaved && (blob >= large || savedSmall < maxSmall);
    if (keep) {
      saved++;
      if (blob < large) savedSmall++;
      // One image has the frame before and the caught frame in its top row.
      // The frame after and the flagged pixels in red over the darkened
      // caught frame are in its bottom row.
      File(out).writeAsBytesSync(
        encodePng(
          2 * c.w,
          2 * c.h,
          _sheet(p, c, n, r.mask),
          alpha: false,
          level: 1,
        ),
      );
    }
    final line = {
      'kind': 'bright',
      'stream': stream,
      'seq': c.seq,
      'frame': c.frame,
      't': c.t,
      'wall': c.wall,
      'scene': c.scene,
      'count': r.count,
      'blob': blob,
      'box': r.box,
      'png': keep ? out : null,
    };
    jsonl.writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append);
    reply.send(line);
  });
}

/// Returns a 2 × 2 RGBA sheet with [p] and [c] in the top row. The bottom row
/// has [n] and [c] darkened with the pixels of [mask] in red.
Uint8List _sheet(_Frame p, _Frame c, _Frame n, Uint8List mask) {
  final w = c.w, h = c.h, sw = 2 * w;
  final out = Uint8List(sw * 2 * h * 4);
  void put(Uint8List src, int ox, int oy) {
    for (var y = 0; y < h; y++) {
      out.setRange(
        ((oy + y) * sw + ox) * 4,
        ((oy + y) * sw + ox + w) * 4,
        src,
        y * w * 4,
      );
    }
  }

  put(p.rgba, 0, 0);
  put(c.rgba, w, 0);
  put(n.rgba, 0, h);
  final marked = Uint8List(w * h * 4);
  for (var i = 0; i < mask.length; i++) {
    final on = mask[i] != 0;
    marked[i * 4] = on ? 255 : c.rgba[i * 4] ~/ 3;
    marked[i * 4 + 1] = on ? 0 : c.rgba[i * 4 + 1] ~/ 3;
    marked[i * 4 + 2] = on ? 0 : c.rgba[i * 4 + 2] ~/ 3;
    marked[i * 4 + 3] = 255;
  }
  put(marked, w, h);
  return out;
}
