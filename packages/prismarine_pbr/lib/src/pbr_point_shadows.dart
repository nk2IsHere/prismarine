import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:vector_math/vector_math_64.dart';

import 'pbr_blocks.dart';
import 'pbr_settings.dart';

/// The name of the depth atlas of the point light shadows.
const pointShadowAtlas = 'pointShadowAtlas';

/// A draw that casts shadows, with its draw for the sun and its bounding
/// sphere in the world.
class PbrCaster {
  PbrCaster(this.sun, this.center, this.radius);
  final DrawPlan sun;
  final Vector3 center;
  final double radius;
}

/// The shadows of the point lights in one depth atlas. Each light with a
/// shadow slot draws six faces of a cube into a row of the atlas. The
/// casters of a face are the draws whose bounding sphere touches its
/// frustum inside the range of the light.
class PbrPointShadows {
  PbrPointShadows(this.settings);
  final PbrSettings settings;

  List<PbrCaster> _casters = const [];
  int _budget = 0, _tile = 0;

  /// The slot of each point light plus one, 0 for none.
  final slotOfLight = Int32List(maxPointLights);

  /// The light of each slot, -1 for a free slot.
  final _lightOfSlot = Int32List(maxPointShadows)..fillRange(0, 8, -1);
  final _score = Float64List(maxPointLights);

  final _draws = _KeptDraws();
  late List<DrawPlan?> _faceDraws;
  final _faces = <FrameBlock>[];
  final _roles = <FrameRole>[];
  final _view = Matrix4.zero(), _projection = Matrix4.zero();
  final _faceVp = Matrix4.zero();
  final _forward = Vector3.zero(), _up = Vector3.zero();
  final _planes = Float64List(24);

  /// The draws of the atlas in this frame.
  int get drawCount => _draws.length;

  /// True when the settings need another atlas or budget.
  bool changed() =>
      settings.pointShadows.budget.clamp(0, maxPointShadows) != _budget ||
      (_budget > 0 && _tileOf(settings.pointShadows.quality) != _tile);

  static int _tileOf(PbrQuality q) => 256 << q.index;

  /// Adds the atlas and the pass of the shadows of [casters].
  // alloc-cold: a new plan on a new size or new settings.
  RenderPassPlan make(
    List<PbrCaster> casters,
    Map<String, TargetSpec> targets,
    Map<Uint8List, Uint8List> blocks,
  ) {
    _casters = casters;
    _budget = settings.pointShadows.budget.clamp(0, maxPointShadows);
    _tile = _tileOf(settings.pointShadows.quality);
    final faces = _budget * 6;
    while (_faces.length < faces) {
      _roles.add(FrameRole('pbr.pointFace${_faces.length}'));
      _faces.add(FrameBlock());
    }
    for (var i = 0; i < faces; i++) {
      blocks[_roles[i].block] = _faces[i].bytes;
    }
    _faceDraws = List<DrawPlan?>.filled(faces * casters.length, null);
    _draws.reserve(faces * casters.length);
    _lightOfSlot.fillRange(0, maxPointShadows, -1);
    slotOfLight.fillRange(0, maxPointLights, 0);
    // A budget of 0 keeps a small cleared atlas for the lit shaders to bind.
    targets[pointShadowAtlas] = TargetSpec(
      _budget == 0 ? 6 : 6 * _tile,
      _budget == 0 ? 1 : _budget * _tile,
      'D32_FLOAT',
    );
    return RenderPassPlan(
      'pointShadows',
      const [],
      const Attachment(pointShadowAtlas, clearDepth: 1),
      _draws,
    );
  }

  /// Gives the shadow slots to the [count] first [lights] with the most
  /// light at the camera at [eye], among those whose range touches the view
  /// of [viewProjection]. Fills the draw list of the atlas. Returns a stamp
  /// of what the atlas shows.
  int select(
    List<PointLight> lights,
    int count,
    Vector3 eye,
    Matrix4 viewProjection,
  ) {
    _draws.length = 0;
    slotOfLight.fillRange(0, maxPointLights, 0);
    if (_budget == 0) return 1;
    _frustum(viewProjection);
    for (var i = 0; i < maxPointLights; i++) {
      _score[i] = 0;
      if (i >= count) continue;
      final l = lights[i];
      if (l.range <= 0 || !_touches(l.position, l.range)) continue;
      final c = l.color;
      final far = l.position.distanceToSquared(eye);
      final d2 = far < 1 ? 1.0 : far;
      final peak = c.x > c.y
          ? (c.x > c.z ? c.x : c.z)
          : (c.y > c.z ? c.y : c.z);
      _score[i] = l.intensity * peak / d2 + 1e-9;
    }
    // A slot stays with its light while the light is among the best.
    for (var s = 0; s < _budget; s++) {
      final l = _lightOfSlot[s];
      if (l < 0 || l >= count || !_best(l)) _lightOfSlot[s] = -1;
    }
    for (var i = 0; i < count; i++) {
      if (!_best(i) || _holds(i)) continue;
      for (var s = 0; s < _budget; s++) {
        if (_lightOfSlot[s] >= 0) continue;
        _lightOfSlot[s] = i;
        break;
      }
    }
    var stamp = _tile * 31 + _budget;
    for (var s = 0; s < _budget; s++) {
      final i = _lightOfSlot[s];
      if (i < 0) continue;
      slotOfLight[i] = s + 1;
      final l = lights[i];
      for (var f = 0; f < 6; f++) {
        _face(s, f, l);
      }
      final p = l.position;
      stamp = (stamp * 31 + i) & 0x3fffffff;
      stamp = (stamp * 31 + (p.x * 1e4).round()) & 0x3fffffff;
      stamp = (stamp * 31 + (p.y * 1e4).round()) & 0x3fffffff;
      stamp = (stamp * 31 + (p.z * 1e4).round()) & 0x3fffffff;
      stamp = (stamp * 31 + (l.range * 1e4).round()) & 0x3fffffff;
    }
    return stamp == 0 ? 1 : stamp;
  }

  /// True when light [i] has a score among the [_budget] best.
  bool _best(int i) {
    final mine = _score[i];
    if (mine <= 0) return false;
    var better = 0;
    for (var j = 0; j < maxPointLights; j++) {
      final o = _score[j];
      if (o > mine || (o == mine && j < i)) better++;
    }
    return better < _budget;
  }

  bool _holds(int light) {
    for (var s = 0; s < _budget; s++) {
      if (_lightOfSlot[s] == light) return true;
    }
    return false;
  }

  /// Writes the camera of face [f] of slot [s] for light [l] and adds the
  /// draws of the casters that it sees.
  void _face(int s, int f, PointLight l) {
    final k = s * 6 + f;
    final axis = f >> 1;
    final sign = f.isEven ? 1.0 : -1.0;
    _forward.setValues(
      axis == 0 ? sign : 0,
      axis == 1 ? sign : 0,
      axis == 2 ? sign : 0,
    );
    if (axis == 1) {
      _up.setValues(0, 0, 1);
    } else {
      _up.setValues(0, 1, 0);
    }
    lookAlong(_view, l.position, _forward, _up);
    perspective(_projection, math.pi / 2, 1, pointShadowNear, l.range);
    _faceVp
      ..setFrom(_projection)
      ..multiply(_view);
    _faces[k].matrix(0, _faceVp);
    final p = l.position;
    final casters = _casters;
    final reach = l.range * settings.pointShadows.reach;
    for (var c = 0; c < casters.length; c++) {
      final caster = casters[c];
      final r = caster.radius;
      final dx = caster.center.x - p.x,
          dy = caster.center.y - p.y,
          dz = caster.center.z - p.z;
      if (dx * dx + dy * dy + dz * dz > (reach + r) * (reach + r)) continue;
      final m = sign * (axis == 0 ? dx : (axis == 1 ? dy : dz));
      final u = axis == 0 ? dy : dx;
      final v = axis == 2 ? dy : dz;
      // The four side planes of a 90 degree face through the light.
      final slack = r * math.sqrt2;
      if (m - u < -slack || m + u < -slack) continue;
      if (m - v < -slack || m + v < -slack) continue;
      _draws.add(_faceDraws[k * casters.length + c] ??= _drawOf(k, s, f, c));
    }
  }

  // alloc-cold: a face draws a caster for the first time.
  DrawPlan _drawOf(int k, int s, int f, int c) {
    final caster = _casters[c];
    final sun = caster.sun;
    final t = _tile.toDouble();
    final blocks = sun.vertexResources.blocks;
    return DrawPlan(
      vertex: sun.vertex,
      pixel: sun.pixel,
      geometry: sun.geometry,
      // Both faces cast, as for the sun. A light inside a closed part sees
      // only the backs of its faces.
      state: sun.state,
      viewport: [f * t, s * t, t, t, 0, 1],
      vertexResources: StageResources(
        blocks: {'Frame': _roles[k].block, 'Draw': blocks['Draw']!},
      ),
      pixelResources: StageResources(
        blocks: {'Frame': _roles[k].block, 'Draw': blocks['Draw']!},
        textures: sun.pixelResources.textures,
        samplers: sun.pixelResources.samplers,
      ),
      label: sun.label,
    );
  }

  /// The planes of the view frustum of [m] with normals into the view, each
  /// as four values a, b, c, d of a x + b y + c z + d.
  void _frustum(Matrix4 m) {
    final s = m.storage;
    for (var p = 0; p < 6; p++) {
      final row = p >> 1;
      final sign = p.isEven ? 1.0 : -1.0;
      for (var j = 0; j < 4; j++) {
        // Row 3 plus or minus row 0, 1 or 2. Depth from 0 takes row 2 alone
        // for the near plane.
        final r3 = s[j * 4 + 3], rk = s[j * 4 + row];
        _planes[p * 4 + j] = row == 2 && p.isEven ? rk : r3 + sign * rk;
      }
    }
  }

  bool _touches(Vector3 c, double r) {
    for (var p = 0; p < 6; p++) {
      final a = _planes[p * 4], b = _planes[p * 4 + 1];
      final cz = _planes[p * 4 + 2], d = _planes[p * 4 + 3];
      // The distance to the plane is v over the length of the normal.
      final v = a * c.x + b * c.y + cz * c.z + d;
      if (v < 0 && v * v > r * r * (a * a + b * b + cz * cz)) return false;
    }
    return true;
  }
}

/// The near plane of the faces of a point light in metres.
const pointShadowNear = 0.05;

/// A list of draws that keeps its storage when it is emptied.
final class _KeptDraws extends ListBase<DrawPlan> {
  List<DrawPlan?> _items = const [];
  int _length = 0;

  // alloc-cold: once per plan.
  void reserve(int n) {
    _items = List<DrawPlan?>.filled(n, null);
    _length = 0;
  }

  @override
  int get length => _length;

  @override
  set length(int n) {
    if (n > _items.length) throw RangeError.range(n, 0, _items.length);
    _length = n;
  }

  @override
  DrawPlan operator [](int i) => _items[i]!;

  @override
  void operator []=(int i, DrawPlan d) => _items[i] = d;

  @override
  void add(DrawPlan d) => _items[_length++] = d;
}
