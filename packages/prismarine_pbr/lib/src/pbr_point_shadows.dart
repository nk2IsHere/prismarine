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
///
/// [nodes] holds a binary tree over the runs of consecutive triangles of the
/// draw. Node i has its first index at 3 i, its index count at 3 i + 1 and
/// the node of its second half at 3 i + 2, or 0 for a run. Its first half is
/// node i + 1. Node 0 is the whole draw. [nodeSpheres] holds the center and
/// the radius of each node in the world. A face of a point light draws a
/// node that lies inside it as one draw and looks into the halves of a node
/// that it cuts. Without nodes a face draws the whole draw.
class PbrCaster {
  PbrCaster(
    this.sun,
    this.center,
    this.radius, {
    Uint32List? nodes,
    Float64List? nodeSpheres,
  }) : nodes = nodes ?? Uint32List(0),
       nodeSpheres = nodeSpheres ?? Float64List(0);
  final DrawPlan sun;
  final Vector3 center;
  final double radius;
  final Uint32List nodes;
  final Float64List nodeSpheres;

  /// The number of nodes, at least 1.
  int get nodeCount => nodes.isEmpty ? 1 : nodes.length ~/ 3;
}

/// The shadows of the point lights in one depth atlas. Each light with a
/// shadow slot draws six faces of a cube into a row of the atlas. A face
/// draws the runs of the draws whose bounding sphere touches its frustum
/// inside the reach of the light, each run that touches the frustum.
///
/// The faces come in three pairs, +x and -x, +y and -y, +z and -z. Each pair
/// keeps the position and the range of the light that it was drawn for in
/// [pairs]. A light that gets a slot draws all pairs at once. A light that
/// moves draws its pairs again in turns over [PbrPointShadowSettings.turns]
/// frames, the pair drawn longest ago first. A pass draws and clears only
/// the faces that change and keeps the rest of the atlas.
class PbrPointShadows {
  PbrPointShadows(this.settings);
  final PbrSettings settings;

  List<PbrCaster> _casters = const [];

  /// The index of the first node of each caster in the draws of a face.
  Int32List _firstNode = Int32List(0);
  int _nodes = 0;
  final _stack = Int32List(64);
  int _budget = 0, _tile = 0;

  /// The slot of each point light plus one, 0 for none.
  final slotOfLight = Int32List(maxPointLights);

  /// The light of each slot, -1 for a free slot.
  final _lightOfSlot = Int32List(maxPointShadows)..fillRange(0, 8, -1);
  final _score = Float64List(maxPointLights);

  /// The position and the range of the light that each pair of faces of
  /// each slot was drawn for, 4 values per pair, pair p of slot s at
  /// 12 s + 4 p. A range of 0 marks a pair that was not drawn.
  final pairs = Float64List(maxPointShadows * 12);

  /// The pair of each slot that was drawn longest ago.
  final _nextPair = Int32List(maxPointShadows);

  final _draws = _KeptDraws();
  late List<DrawPlan?> _faceDraws;
  late List<DrawPlan> _clears;
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

  // alloc-cold: a new plan on a new size or new settings.
  /// Adds the atlas and the pass of the shadows of [casters].
  RenderPassPlan make(
    List<PbrCaster> casters,
    Map<String, TargetSpec> targets,
    Map<Uint8List, Uint8List> blocks,
  ) {
    _casters = casters;
    _firstNode = Int32List(casters.length);
    _nodes = 0;
    for (var c = 0; c < casters.length; c++) {
      _firstNode[c] = _nodes;
      _nodes += casters[c].nodeCount;
    }
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
    _faceDraws = List<DrawPlan?>.filled(faces * _nodes, null);
    _clears = [for (var k = 0; k < faces; k++) _clearOf(k)];
    _draws.reserve(faces * (_nodes + 1));
    _lightOfSlot.fillRange(0, maxPointShadows, -1);
    slotOfLight.fillRange(0, maxPointLights, 0);
    pairs.fillRange(0, pairs.length, 0);
    // The atlas is new and holds no face.
    targets[pointShadowAtlas] = TargetSpec(
      _budget == 0 ? 6 : 6 * _tile,
      _budget == 0 ? 1 : _budget * _tile,
      'D32_FLOAT',
    );
    // A budget of 0 keeps a small cleared atlas for the lit shaders to bind.
    return RenderPassPlan(
      'pointShadows',
      const [],
      Attachment(pointShadowAtlas, clearDepth: _budget == 0 ? 1 : null),
      _draws,
    );
  }

  /// Gives the shadow slots to the [count] first [lights] with the most
  /// light at the camera at [eye], among those whose range touches the view
  /// of [viewProjection]. Fills the draw list of the atlas with the faces
  /// that change. Returns a stamp of what the atlas shows.
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
      if (l < 0 || l >= count || !_best(l)) _free(s);
    }
    for (var i = 0; i < count; i++) {
      if (!_best(i) || _holds(i)) continue;
      for (var s = 0; s < _budget; s++) {
        if (_lightOfSlot[s] >= 0) continue;
        _lightOfSlot[s] = i;
        break;
      }
    }
    final turns = settings.pointShadows.turns.clamp(1, 3);
    final perFrame = (3 + turns - 1) ~/ turns;
    var stamp = _tile * 31 + _budget;
    for (var s = 0; s < _budget; s++) {
      final i = _lightOfSlot[s];
      if (i < 0) continue;
      slotOfLight[i] = s + 1;
      final l = lights[i];
      var drawn = 0;
      // A pair that was not drawn yet is drawn now. Otherwise up to
      // [perFrame] pairs whose light moved since their draw are drawn again.
      for (var p = 0; p < 3; p++) {
        if (pairs[s * 12 + p * 4 + 3] == 0) {
          _drawPair(s, p, l);
          drawn = 3;
        }
      }
      final from = _nextPair[s];
      for (var k = 0; k < 3 && drawn < perFrame; k++) {
        final p = (from + k) % 3;
        if (_same(s, p, l)) continue;
        _drawPair(s, p, l);
        _nextPair[s] = (p + 1) % 3;
        drawn++;
      }
      stamp = (stamp * 31 + i) & 0x3fffffff;
      for (var v = s * 12; v < s * 12 + 12; v++) {
        stamp = (stamp * 31 + (pairs[v] * 1e4).round()) & 0x3fffffff;
      }
    }
    return stamp == 0 ? 1 : stamp;
  }

  void _free(int s) {
    _lightOfSlot[s] = -1;
    for (var v = s * 12; v < s * 12 + 12; v++) {
      pairs[v] = 0;
    }
    _nextPair[s] = 0;
  }

  bool _same(int s, int p, PointLight l) {
    final at = s * 12 + p * 4;
    final q = l.position;
    return pairs[at] == q.x &&
        pairs[at + 1] == q.y &&
        pairs[at + 2] == q.z &&
        pairs[at + 3] == l.range;
  }

  void _drawPair(int s, int p, PointLight l) {
    _face(s, p * 2, l);
    _face(s, p * 2 + 1, l);
    final at = s * 12 + p * 4;
    final q = l.position;
    pairs
      ..[at] = q.x
      ..[at + 1] = q.y
      ..[at + 2] = q.z
      ..[at + 3] = l.range;
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
  /// draw that clears it and the draws of the runs that it sees.
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
    _draws.add(_clears[k]);
    final p = l.position;
    final casters = _casters;
    final reach = l.range * settings.pointShadows.reach;
    for (var c = 0; c < casters.length; c++) {
      final caster = casters[c];
      final center = caster.center;
      final whole = _sees(
        axis,
        sign,
        center.x - p.x,
        center.y - p.y,
        center.z - p.z,
        caster.radius,
        reach,
      );
      if (whole == _out) continue;
      final first = _firstNode[c];
      final nodes = caster.nodes;
      if (nodes.isEmpty || whole == _inside) {
        _add(k, s, f, c, 0, first);
        continue;
      }
      final spheres = caster.nodeSpheres;
      final stack = _stack;
      var top = 0;
      stack[top++] = 0;
      while (top > 0) {
        final i = stack[--top];
        final seen = i == 0
            ? whole
            : _sees(
                axis,
                sign,
                spheres[i * 4] - p.x,
                spheres[i * 4 + 1] - p.y,
                spheres[i * 4 + 2] - p.z,
                spheres[i * 4 + 3],
                double.infinity,
              );
        if (seen == _out) continue;
        final second = nodes[i * 3 + 2];
        if (seen == _inside || second == 0 || top + 2 > stack.length) {
          _add(k, s, f, c, i, first + i);
          continue;
        }
        stack[top++] = second;
        stack[top++] = i + 1;
      }
    }
  }

  void _add(int k, int s, int f, int c, int node, int at) =>
      _draws.add(_faceDraws[k * _nodes + at] ??= _drawOf(k, s, f, c, node));

  static const _out = 0, _cut = 1, _inside = 2;

  /// Returns [_out] when the sphere of radius [r] at the offset [dx], [dy],
  /// [dz] from the light is beyond [reach] or outside the face along [axis]
  /// with [sign], [_inside] when it lies within both and [_cut] otherwise.
  static int _sees(
    int axis,
    double sign,
    double dx,
    double dy,
    double dz,
    double r,
    double reach,
  ) {
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 > (reach + r) * (reach + r)) return _out;
    final m = sign * (axis == 0 ? dx : (axis == 1 ? dy : dz));
    final u = axis == 0 ? dy : dx;
    final v = axis == 2 ? dy : dz;
    // The four side planes of a 90 degree face through the light.
    final slack = r * math.sqrt2;
    final a = m - u, b = m + u, c = m - v, e = m + v;
    if (a < -slack || b < -slack || c < -slack || e < -slack) return _out;
    final near = r < reach && d2 <= (reach - r) * (reach - r);
    return near && a >= slack && b >= slack && c >= slack && e >= slack
        ? _inside
        : _cut;
  }

  // alloc-cold: a face draws a node for the first time.
  DrawPlan _drawOf(int k, int s, int f, int c, int node) {
    final caster = _casters[c];
    final sun = caster.sun;
    final t = _tile.toDouble();
    final blocks = sun.vertexResources.blocks;
    final geometry = sun.geometry;
    final nodes = caster.nodes;
    return DrawPlan(
      vertex: sun.vertex,
      pixel: sun.pixel,
      geometry: nodes.isEmpty || geometry is! DrawMeshGeometry
          ? geometry
          : DrawMeshGeometry(
              geometry.mesh,
              geometry.ibuffer,
              nodes[node * 3],
              nodes[node * 3 + 1],
            ),
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

  // alloc-cold: once per face of a new plan.
  DrawPlan _clearOf(int k) {
    final t = _tile.toDouble();
    return DrawPlan(
      vertex: PbrShaderIds.depthClearVertex,
      pixel: PbrShaderIds.nullPixel,
      geometry: InlineGeometry(_screenTriangle, 8, const {
        0: ('R32G32_FLOAT', 0),
      }, 3),
      state: _clearState,
      viewport: [(k % 6) * t, (k ~/ 6) * t, t, t, 0, 1],
      vertexResources: StageResources(),
      pixelResources: StageResources(),
      label: 'clear point shadow face',
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

/// The state of the draw that clears a face to the far depth.
const _clearState = DrawState(cull: 'none', depthFunc: 'always');

final _screenTriangle = Float32List.fromList([
  -1, -1, 3, -1, -1, 3, //
]).buffer.asUint8List();

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
