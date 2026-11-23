import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_loop/prismarine_loop.dart';
import 'package:prismarine_math/clamp.dart';
import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:prismarine_pbr/prismarine_pbr.dart';

import 'fly_camera.dart';
import 'light_show.dart';
import 'sample_panel.dart';
import 'sample_renderer.dart';
import 'sample_samples.dart';

/// The interactive view of the sample: the scene in the window, the fly
/// camera, the moving lights and the debug panel on F1.
class SampleView extends StatefulWidget {
  const SampleView(this.renderer, {super.key, this.panel = false});
  final SampleRenderer renderer;

  /// Shows the debug panel from the start.
  final bool panel;

  @override
  State<SampleView> createState() => _SampleViewState();
}

class _SampleViewState extends State<SampleView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final SampleRenderer _r = widget.renderer;
  final _camera = FlyCamera();
  final _view = PbrCamera();
  late final LightShow _lights;
  final _pads = HostPads();
  final _pad = PadState();
  final _pace = FramePace();
  final _gc = GcPacing(enabled: true);
  final _limiter = MetalFrameLimiter.create();
  final _samples = SampleSamples();
  final _repaint = ValueNotifier<int>(0);
  final _focus = FocusNode();
  final _clock = Stopwatch()..start();
  final _stepClock = Stopwatch();
  bool _panel = false, _animate = true;
  double _time = 0;
  int _width = 0, _height = 0;

  @override
  void initState() {
    super.initState();
    _lights = LightShow.forScene(
      _r.builder.boundsMin,
      _r.builder.boundsMax,
      _r.lamps,
      volume: _r.builder.giVolume,
    );
    final cams = _r.cameras;
    if (cams.isNotEmpty) {
      _camera.place(cams.first.world);
      _view.yfov = cams.first.yfov;
    } else {
      _camera.frame(_r.builder.boundsMin, _r.builder.boundsMax, _view.yfov);
    }
    _r.builder.lights.addAll(_lights.lights);
    _panel = widget.panel;
    _samples.measureLag(_panel);
    _r.onFrame = _frameDone;
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    _repaint.dispose();
    _r.onFrame = null;
    super.dispose();
  }

  void _frameDone() => _repaint.value++;

  void _tick(Duration _) {
    final f = _samples.beginFrame();
    _gc.beginFrame();
    _limiter?.beginFrame();
    final now = _clock.elapsedMicroseconds;
    final step = _pace.begin(now);
    if (step >= 0) {
      _stepClock
        ..reset()
        ..start();
      final dt = clampDouble(_pace.stepSeconds, 0, 0.1);
      _pads.readInto(_pad);
      f.dt = dt;
      _camera.step(dt, _pad, _view);
      if (_animate) _time += dt;
      _lights.place(_time);
      f.add('step', _stepClock.elapsedMicroseconds / 1000);
      final submitted = _width > 0 && _r.inFlight < 2;
      _r.timed = _panel;
      if (submitted) _r.submit(_view, _width, _height, dt: dt);
      final runner = _r.runner;
      f
        ..add('build', _r.lastBuildMs)
        ..add('record', runner.lastRecordMs);
      if (runner.timedParts.isEmpty) {
        f.add('gpu', runner.lastGpuOwnMs);
      } else {
        final sections = _r.gpuSections;
        for (var i = 0; i < sections.length; i++) {
          f.add(sections[i], runner.lastPartGpuMs[i]);
        }
      }
      _pace.end(
        _clock.elapsedMicroseconds,
        presented: submitted,
        shown: _r.finished,
        simMs: 0,
        uiMs: _stepClock.elapsedMicroseconds / 1000,
        buildMs: _r.lastBuildMs,
        gpuMs: runner.lastGpuOwnMs,
      );
    }
    f.tick = (_clock.elapsedMicroseconds - now) / 1000;
    _samples.endFrame(f, keepOpen: true);
    _gc.endFrame();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final down = e is! KeyUpEvent;
    final k = e.logicalKey;
    final c = _camera;
    if (k == LogicalKeyboardKey.keyW) {
      c.forward = down;
    } else if (k == LogicalKeyboardKey.keyS) {
      c.back = down;
    } else if (k == LogicalKeyboardKey.keyA) {
      c.left = down;
    } else if (k == LogicalKeyboardKey.keyD) {
      c.right = down;
    } else if (k == LogicalKeyboardKey.keyE) {
      c.up = down;
    } else if (k == LogicalKeyboardKey.keyQ) {
      c.down = down;
    } else if (k == LogicalKeyboardKey.shiftLeft ||
        k == LogicalKeyboardKey.shiftRight) {
      c.fast = down;
    } else if (k == LogicalKeyboardKey.f1 && e is KeyDownEvent) {
      setState(() => _panel = !_panel);
      _samples.measureLag(_panel);
    } else if (k == LogicalKeyboardKey.space && e is KeyDownEvent) {
      _animate = !_animate;
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scene = LayoutBuilder(
      builder: (context, box) {
        _width = (box.maxWidth * dpr).round();
        _height = (box.maxHeight * dpr).round();
        return Listener(
          onPointerMove: (e) {
            if (e.buttons != 0) _camera.look(e.delta.dx, e.delta.dy);
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _camera.scaleSpeed(e.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2);
            }
          },
          child: CustomPaint(
            painter: FramePainter(_r, _repaint),
            size: Size.infinite,
          ),
        );
      },
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: scene)),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: CreditLine(_r.credits, _clock),
          ),
          if (_panel)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: 360,
              child: SamplePanel(
                samples: _samples,
                renderer: _r,
                lights: _lights,
                camera: _camera,
                onAnimate: (v) => _animate = v,
                animate: () => _animate,
              ),
            ),
        ],
      ),
    );
  }
}

/// Paints the last finished frame of [renderer] over the whole canvas.
class FramePainter extends CustomPainter {
  FramePainter(this.renderer, Listenable repaint) : super(repaint: repaint);
  final SampleRenderer renderer;
  static gpu.Texture? _shown;
  static ui.Image? _image;

  @override
  void paint(Canvas canvas, Size size) {
    final t = renderer.presented;
    if (t == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }
    if (!identical(t, _shown)) {
      _image?.dispose();
      // alloc: the engine makes a new image of each finished frame.
      _image = t.asImage();
      _shown = t;
    }
    final img = _image!;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      _paint,
    );
  }

  static final _paint = Paint()..filterQuality = FilterQuality.low;

  @override
  bool shouldRepaint(FramePainter old) => false;
}
