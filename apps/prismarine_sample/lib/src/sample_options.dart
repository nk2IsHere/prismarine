import 'package:prismarine_pbr/builder.dart';

/// The options of the command line that set the effects of the renderer,
/// with their help text.
const renderOptions = {
  'taa': 'off, low, medium or high. Medium by default.',
  'bloom': 'off, low, medium or high. Medium by default.',
  'exposure': 'auto, or a fixed factor such as 1.5. Auto by default.',
  'tonemap': 'acesFit, aces, agx or neutral. agx by default.',
  'point-shadows':
      'The lights that cast shadows and the quality, such as 4,high. 2,medium by default, 0 on macOS.',
  'fog': 'off, low, medium or high. Medium by default.',
  'fog-density': 'The extinction of the fog per metre.',
  'fog-anisotropy': 'The forward scattering of the fog, from -1 to 1.',
  'ev': 'The exposure compensation of auto exposure in EV.',
  'lights': 'The number of point lights of the smoke frames, 8 by default.',
  'gi': 'off, low, medium or high, the indirect light. Medium by default.',
  'gi-off':
      'The parts of the indirect light to switch off, of sky, probes, ao and ssr, such as ao,ssr.',
  'gi-view':
      'diffuse, occlusion, reflections or probes, a view of one part of the indirect light.',
};

/// The parts of the indirect light that the options switch off.
Set<String> giOff(String? Function(String name) opt) => opt('gi') == 'off'
    ? const {'sky', 'probes', 'ao', 'ssr'}
    : {...?opt('gi-off')?.split(',')};

/// Sets the effects of [s] from the options that [opt] returns by name.
/// Throws a [FormatException] for a value that no option takes.
void applyRenderOptions(PbrSettings s, String? Function(String name) opt) {
  final post = s.post;
  if (opt('taa') case final v?) {
    post.taa = v != 'off';
    if (post.taa) post.taaQuality = _quality(v);
  }
  if (opt('bloom') case final v?) {
    post.bloom = v != 'off';
    if (post.bloom) post.bloomQuality = _quality(v);
  }
  if (opt('exposure') case final v?) {
    post.autoExposure = v == 'auto';
    if (!post.autoExposure) s.exposure = double.parse(v);
  }
  if (opt('tonemap') case final v?) {
    post.toneMap = PbrToneMap.values.firstWhere(
      (t) => t.name == v,
      orElse: () => throw FormatException('no tone map $v'),
    );
  }
  if (opt('point-shadows') case final v?) {
    final parts = v.split(',');
    s.pointShadows.budget = int.parse(parts[0]).clamp(0, maxPointShadows);
    if (parts.length > 1) s.pointShadows.quality = _quality(parts[1]);
  }
  if (opt('fog') case final v?) {
    s.volume.enabled = v != 'off';
    if (s.volume.enabled) s.volume.quality = _quality(v);
  }
  if (opt('fog-density') case final v?) s.volume.density = double.parse(v);
  if (opt('fog-anisotropy') case final v?) {
    s.volume.anisotropy = double.parse(v);
  }
  if (opt('ev') case final v?) post.compensation = double.parse(v);
  final gi = s.gi;
  if (opt('gi') case final v? when v != 'off') {
    gi.quality = GiQuality.values.firstWhere(
      (q) => q.name == v,
      orElse: () => throw FormatException('no indirect light preset $v'),
    );
  }
  if (opt('gi-view') case final v?) {
    gi.debugView = GiDebugView.values.firstWhere(
      (d) => d.name == v,
      orElse: () => throw FormatException('no indirect light view $v'),
    );
  }
  final off = giOff(opt);
  gi
    ..sky = !off.contains('sky')
    ..probes = !off.contains('probes')
    ..ambientOcclusion = !off.contains('ao')
    ..reflections = !off.contains('ssr');
}

PbrQuality _quality(String v) => PbrQuality.values.firstWhere(
  (q) => q.name == v,
  orElse: () => throw FormatException('no quality $v'),
);
