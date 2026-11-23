import 'package:flutter/material.dart';
import 'package:prismarine_debug/prismarine_debug.dart';
import 'package:prismarine_pbr/prismarine_pbr.dart';

import 'sample_renderer.dart';

/// The sections of the panel for the effects of the renderer: anti-aliasing,
/// exposure and bloom, the point light shadows and the fog. Each title holds
/// the GPU time of the effect in the last frame. [changed] runs a change and
/// rebuilds the panel.
List<Widget> effectSections(
  PanelContext p,
  SampleRenderer r,
  void Function(VoidCallback change) changed,
) {
  final s = r.builder.settings;
  final post = s.post;
  final points = s.pointShadows;
  final fog = s.volume;
  final style = p.small;

  Widget toggle(String label, bool value, void Function(bool) set) =>
      SwitchListTile(
        dense: true,
        title: Text(label, style: style),
        value: value,
        onChanged: (v) => changed(() => set(v)),
      );

  Widget choice<T>(
    String label,
    List<T> values,
    T current,
    String Function(T) name,
    void Function(T) set,
  ) => Row(
    children: [
      SizedBox(width: 110, child: Text(label, style: style)),
      Expanded(
        child: Wrap(
          children: [
            for (final v in values)
              TextButton(
                onPressed: () => changed(() => set(v)),
                child: Text(
                  name(v),
                  style: style.copyWith(
                    fontWeight: v == current
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget quality(PbrQuality current, void Function(PbrQuality) set) =>
      choice('Quality', PbrQuality.values, current, (q) => q.name, set);

  Widget slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) set,
  ) => Row(
    children: [
      SizedBox(width: 110, child: Text(label, style: style)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (v) => changed(() => set(v)),
        ),
      ),
      SizedBox(width: 44, child: Text(value.toStringAsFixed(3), style: style)),
    ],
  );

  return [
    PanelSection(
      'Anti-aliasing, ${_cost(r, 'taa')}',
      id: 'Anti-aliasing',
      open: p.open,
      children: [
        toggle('TAA', post.taa, (v) => post.taa = v),
        if (post.taa) quality(post.taaQuality, (q) => post.taaQuality = q),
      ],
    ),
    PanelSection(
      'Exposure and bloom, ${_cost(r, 'exposure and bloom')}',
      id: 'Exposure and bloom',
      open: p.open,
      children: [
        toggle(
          'Auto exposure',
          post.autoExposure,
          (v) => post.autoExposure = v,
        ),
        if (post.autoExposure)
          slider(
            'Compensation',
            post.compensation,
            -3,
            3,
            (v) => post.compensation = v,
          )
        else
          slider('Exposure', s.exposure, 0.1, 4, (v) => s.exposure = v),
        choice(
          'Tone map',
          PbrToneMap.values,
          post.toneMap,
          (t) => t.name,
          (t) => post.toneMap = t,
        ),
        toggle('Bloom', post.bloom, (v) => post.bloom = v),
        if (post.bloom) ...[
          quality(post.bloomQuality, (q) => post.bloomQuality = q),
          slider(
            'Strength',
            post.bloomStrength,
            0,
            0.3,
            (v) => post.bloomStrength = v,
          ),
        ],
      ],
    ),
    PanelSection(
      'Point light shadows, ${_cost(r, 'point shadows')}',
      id: 'Point light shadows',
      open: p.open,
      children: [
        slider(
          'Lights',
          points.budget.toDouble(),
          0,
          maxPointShadows.toDouble(),
          (v) => points.budget = v.round(),
        ),
        quality(points.quality, (q) => points.quality = q),
        slider('Reach', points.reach, 0.1, 1, (v) => points.reach = v),
        slider('Bias', points.bias, 0, 4, (v) => points.bias = v),
        Text('${r.builder.pointShadowDraws} draws this frame', style: style),
      ],
    ),
    PanelSection(
      'Fog, ${_cost(r, 'fog')}',
      id: 'Fog',
      open: p.open,
      children: [
        toggle('Fog', fog.enabled, (v) => fog.enabled = v),
        if (fog.enabled) ...[
          quality(fog.quality, (q) => fog.quality = q),
          slider('Density', fog.density, 0, 0.05, (v) => fog.density = v),
          slider(
            'Height falloff',
            fog.heightFalloff,
            0,
            0.5,
            (v) => fog.heightFalloff = v,
          ),
          slider(
            'Anisotropy',
            fog.anisotropy,
            -0.9,
            0.9,
            (v) => fog.anisotropy = v,
          ),
          slider('Sun', fog.sun, 0, 4, (v) => fog.sun = v),
          slider('Point lights', fog.points, 0, 4, (v) => fog.points = v),
          slider('Ambient', fog.ambient, 0, 4, (v) => fog.ambient = v),
          slider('History', fog.history, 0, 0.98, (v) => fog.history = v),
        ],
      ],
    ),
  ];
}

/// The GPU time of the timed part [label] in the last frame.
String _cost(SampleRenderer r, String label) {
  final i = r.builder.partLabels.indexOf(label);
  if (i < 0) return 'off';
  return 'GPU ${r.runner.lastPartGpuMs[i].toStringAsFixed(2)} ms';
}
