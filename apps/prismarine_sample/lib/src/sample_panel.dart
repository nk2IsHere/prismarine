import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

import 'fly_camera.dart';
import 'light_show.dart';
import 'sample_renderer.dart';
import 'sample_samples.dart';

/// The source page and the licence of the model.
const sourcePage =
    'https://www.intel.com/content/www/us/en/developer/topic-technology/'
    'graphics-research/samples.html';
const licenceLine =
    'Intel Sponza, Creative Commons Attribution 4.0 International, '
    'https://creativecommons.org/licenses/by/4.0/';

/// The debug panel of the sample on [DebugPanelShell]: the frame rate and
/// the counts, the frame graph and the settings of the lights, the sun, the
/// exposure, the shadow map and the camera, then the credits.
class SamplePanel extends StatefulWidget {
  const SamplePanel({
    super.key,
    required this.samples,
    required this.renderer,
    required this.lights,
    required this.camera,
    required this.animate,
    required this.onAnimate,
  });

  final SampleSamples samples;
  final SampleRenderer renderer;
  final LightShow lights;
  final FlyCamera camera;
  final bool Function() animate;
  final void Function(bool on) onAnimate;

  @override
  State<SamplePanel> createState() => _SamplePanelState();
}

class _SamplePanelState extends State<SamplePanel> {
  late final Timer _timer;
  double _azimuth = 0, _elevation = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.renderer.builder.settings.sunDirection;
    _elevation = math.asin(d.y.clamp(-1.0, 1.0));
    _azimuth = math.atan2(d.z, d.x);
    // The panel's texts rebuild four times a second, the graph each frame.
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _setSun() {
    widget.renderer.builder.settings.sunDirection.setValues(
      math.cos(_elevation) * math.cos(_azimuth),
      math.sin(_elevation),
      math.cos(_elevation) * math.sin(_azimuth),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) set,
    TextStyle style,
  ) => Row(
    children: [
      SizedBox(width: 110, child: Text(label, style: style)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (v) => setState(() => set(v)),
        ),
      ),
      SizedBox(width: 44, child: Text(value.toStringAsFixed(2), style: style)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.renderer;
    final s = r.builder.settings;
    return Theme(
      data: ThemeData.dark(),
      child: DebugPanelShell(
        samples: widget.samples,
        header: (context, p) => [
          Text(
            '${widget.samples.fps.toStringAsFixed(0)} fps, '
            '${r.builder.drawCount} draws, GPU '
            '${r.runner.lastGpuOwnMs.toStringAsFixed(1)} ms, record '
            '${r.runner.lastRecordMs.toStringAsFixed(1)} ms, '
            '${r.runner.lastRetained} kept passes',
            style: p.small,
          ),
          Text(
            'W A S D to move, Q and E down and up, Shift faster, a mouse '
            'drag to turn, the wheel for speed, Space stops the lights, F1 '
            'hides the panel.',
            style: p.small,
          ),
        ],
        sections: (context, p) => [
          PanelSection(
            'Lights',
            open: p.open,
            children: [
              SwitchListTile(
                dense: true,
                title: Text('Move the lights', style: p.small),
                value: widget.animate(),
                onChanged: (v) => setState(() => widget.onAnimate(v)),
              ),
              SwitchListTile(
                dense: true,
                title: Text('Light markers', style: p.small),
                value: s.lightMarkers,
                onChanged: (v) => setState(() => s.lightMarkers = v),
              ),
              _slider(
                'Point lights',
                r.builder.lights.length.toDouble(),
                0,
                widget.lights.lights.length.toDouble(),
                (v) => r.builder.lights
                  ..clear()
                  ..addAll(widget.lights.lights.take(v.round())),
                p.small,
              ),
              _slider(
                'Intensity',
                widget.lights.intensity,
                0,
                60,
                (v) => widget.lights.intensity = v,
                p.small,
              ),
              _slider(
                'Range',
                widget.lights.range,
                1,
                30,
                (v) => widget.lights.range = v,
                p.small,
              ),
            ],
          ),
          PanelSection(
            'Sun',
            open: p.open,
            children: [
              SwitchListTile(
                dense: true,
                title: Text('Shadows', style: p.small),
                value: s.shadows,
                onChanged: (v) => setState(() => s.shadows = v),
              ),
              SwitchListTile(
                dense: true,
                title: Text('Shadow map view', style: p.small),
                value: s.showShadowMap,
                onChanged: (v) => setState(() => s.showShadowMap = v),
              ),
              _slider(
                'Intensity',
                s.sunIntensity,
                0,
                30,
                (v) => s.sunIntensity = v,
                p.small,
              ),
              _slider('Elevation', _elevation, 0.05, 1.55, (v) {
                _elevation = v;
                _setSun();
              }, p.small),
              _slider('Azimuth', _azimuth, -math.pi, math.pi, (v) {
                _azimuth = v;
                _setSun();
              }, p.small),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text('Shadow map', style: p.small),
                  ),
                  for (final size in const [1024, 2048, 4096])
                    TextButton(
                      onPressed: () => setState(() => s.shadowSize = size),
                      child: Text(
                        '$size',
                        style: p.small.copyWith(
                          fontWeight: s.shadowSize == size
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          PanelSection(
            'Camera',
            open: p.open,
            children: [
              _slider(
                'Exposure',
                s.exposure,
                0.1,
                4,
                (v) => s.exposure = v,
                p.small,
              ),
              _slider(
                'Speed',
                widget.camera.speed,
                0.1,
                20,
                (v) => widget.camera.speed = v,
                p.small,
              ),
              Text(
                'Position ${widget.camera.position.x.toStringAsFixed(2)}, '
                '${widget.camera.position.y.toStringAsFixed(2)}, '
                '${widget.camera.position.z.toStringAsFixed(2)}',
                style: p.small,
              ),
            ],
          ),
          PanelSection(
            'Credits',
            open: p.open,
            initiallyExpanded: false,
            children: [
              for (final c in r.credits) ...[
                SelectableText(c, style: p.small),
                const SizedBox(height: 8),
              ],
              SelectableText('$licenceLine\n$sourcePage', style: p.small),
            ],
          ),
        ],
      ),
    );
  }
}

/// The first credit line of the model with its licence, shown for the
/// first ten seconds of [clock].
class CreditLine extends StatefulWidget {
  const CreditLine(this.credits, this.clock, {super.key});
  final List<String> credits;
  final Stopwatch clock;

  @override
  State<CreditLine> createState() => _CreditLineState();
}

class _CreditLineState extends State<CreditLine> {
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    final left = 10000 - widget.clock.elapsedMilliseconds;
    _hide = Timer(
      Duration(milliseconds: left < 0 ? 0 : left),
      () => setState(() {}),
    );
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.clock.elapsedMilliseconds >= 10000 || widget.credits.isEmpty) {
      return const SizedBox.shrink();
    }
    final first = widget.credits.first.split('\n').first;
    return Text(
      '$first $licenceLine',
      style: const TextStyle(
        color: Color(0xCCFFFFFF),
        fontSize: 12,
        shadows: [Shadow(blurRadius: 3)],
      ),
    );
  }
}
