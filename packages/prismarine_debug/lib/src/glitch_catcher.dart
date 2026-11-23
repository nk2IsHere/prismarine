// The glitch catcher: every frame the history ring keeps (the
// image the window was given: the 3D frame copied on the GPU right after it
// was drawn, with the UI scenes blended over it) is read back and compared
// with the frames shown before and after it. A frame with a bright patch
// that neither neighbour has, while the neighbours agree with each other, is
// a one-frame artefact (such as GPU-race triangles): the three frames
// and a mask of the flagged pixels go to `<run>/caught/`, one line each in
// `caught.jsonl`. A dump re-renders what the game state gives and the
// review scrubs the ring; this keeps what was actually drawn, GPU races
// included.
//
// Off by default: a read-back (640 × 360, through the raster thread) a frame.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'frame_history.dart';
import 'issue.dart';
import 'png.dart';

class GlitchCatcher {
  GlitchCatcher(this.dir, {this.log});

  /// Where the caught frames go (`<run>/caught`).
  final String dir;
  final void Function(String line)? log;

  /// Read-backs in flight at most; a frame past that isn't checked (and its
  /// neighbours aren't checked against it).
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

  /// [FrameHistory.onFrameDone]: reads [frame] back and hands it to the
  /// checker with [seq] and [meta].
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

  /// A frame the window showed (WindowSurfaceReader), [width] wide: checked
  /// against the window's frames before and after it. It carries the newest
  /// history frame's time.
  void windowFrame(Uint8List rgba, int width, int height) {
    _start();
    windowFrames++;
    final m = _last;
    // PRISMARINE_CATCH_SAVE=<t0>:<t1>: every window frame in that stretch of
    // game time is kept as well (window_all/), to look at a moment frame by
    // frame.
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
              encodePng(bytes.materialize().asUint8List(), width, height),
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

  /// The run's summary line.
  String get summary =>
      'catch: $read history frames read back, $dropped not checked '
      '(read-backs busy), $windowFrames window frames read, $flagged '
      'flagged${flagged > 0 ? ' ($dir)' : ''}';

  void close() {
    if (_worker case final w?) w.send(null);
    _port?.close();
  }
}

/// Writes the history's newest [count] frames (the images the window was
/// given) into [dir] as `shown_<k>_f<frame>.png` (k = 0 the newest): a
/// dump's re-rendered screenshot can't show a GPU glitch, these can.
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
        File(
          path,
        ).writeAsBytesSync(encodePng(bytes.materialize().asUint8List(), w, h));
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

/// What makes a pixel part of a one-frame bright artefact: bright in the
/// frame, and [rise] levels above every pixel of both neighbours within
/// [reach] pixels (so whatever moved a little between the frames, a rim
/// light on a swinging arm, isn't taken for one).
class GlitchThresholds {
  const GlitchThresholds({
    this.bright = 150,
    this.rise = 60,
    this.reach = 8,
    this.grey = 64,
    this.minBlob = 60,
  });
  final int bright, rise, reach;

  /// How far from grey a flagged pixel may be (max − min of its R, G, B):
  /// the artefacts are white; a saturated rim light on a moving arm isn't.
  final int grey;

  /// The pixels the largest connected patch of flagged pixels needs (at the
  /// ring's 640 × 360): a stretched triangle is one patch; sparkles, embers
  /// and lip-sync mouth shapes that change for a frame are many small ones.
  final int minBlob;
}

/// The pixels of [cur] that are a one-frame bright artefact against [prev]
/// and [next] (all luma, one byte a pixel, the same size): the count, the
/// bounding box (x0, y0, x1, y1) and a mask (255 where flagged).
({int count, List<int> box, Uint8List mask}) brightTransient(
  Uint8List prev,
  Uint8List cur,
  Uint8List next,
  int w, {
  Uint8List? rgba,
  GlitchThresholds th = const GlitchThresholds(),
}) {
  final h = cur.length ~/ w;
  // The brightest of either neighbour within [reach]: a max filter, rows
  // then columns.
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

/// The size of the largest 4-connected patch of set pixels in [mask].
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
  // Every large catch is kept; small ones (lip-sync mouth shapes, sparks)
  // only up to a few, so a long run's folder stays small.
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
    // Read-backs can finish out of order: keep the window in seq order, and
    // restart it at a hole.
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
      // One image: the frame before | the caught frame, the frame after |
      // the flagged pixels in red over the caught frame, darkened.
      File(
        out,
      ).writeAsBytesSync(encodePng(_sheet(p, c, n, r.mask), 2 * c.w, 2 * c.h));
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

/// A 2 × 2 sheet (RGBA): [p] | [c] over [n] | [c] darkened with [mask]'s
/// pixels red.
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
