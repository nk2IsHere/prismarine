// Draws kept from frame to frame (perf: a frame's full-screen passes, its
// post, ambient occlusion, glow, depth of field, anti-aliasing and mips,
// made ~90 draws anew every frame, each decoded, bound and cached again on
// the UI isolate though most were the same; mesh draws kept by label too).
import 'dart:collection';
import 'dart:typed_data';

import '../plan/frame_plan.dart';

/// A frame memory's draws by pass and position (or a caller's place key
/// and 0: mesh draws by label). A builder's screen draws and [kept] give
/// last frame's draw object again when all it draws is the same (shaders,
/// state, viewport, its blocks' bytes, textures and samplers), so the codec
/// names it by id and the runner binds it from what it kept.
///
/// A kept draw holds its own copy of each block's bytes, never the
/// caller's list, which a caller may fill anew next frame. A block whose
/// bytes change from frame to frame (the camera, the scene clock) is bound
/// by a frame role of the draw's slot, its bytes given with each plan, so
/// the draw stays the same object.
final class DrawKeep {
  final _byPass = <String, List<DrawPlan?>>{};

  /// The role blocks this keep gave its draws' changing blocks.
  final _ours = HashSet<Uint8List>.identity();

  /// The bytes each of [_ours] was last given ([giveAgain]).
  final _given = HashMap<Uint8List, Uint8List>.identity();

  /// This keep's part of its roles' names (roles are one per name in an
  /// isolate; another memory's slot of the same name is another role).
  final int _id = _keeps++;
  static int _keeps = 0;
  static final _viewport = Float64List(6);

  /// The draw at [at] in pass [pass] last frame when it matches; else null.
  DrawPlan? match(
    String pass,
    int at,
    String label,
    String vertex,
    String? pixel,
    DrawState state,
    // x, y, w, h, min and max depth, typed (perf: six doubles boxed per
    // call as arguments).
    Float64List viewport,
    Map<String, Uint8List> vsBlocks,
    Map<String, Uint8List> blocks,
    Map<String, TextureRef> textures,
    Map<int, SamplerState> samplers,
    int stencilRef,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    final list = _byPass[pass];
    if (list == null || at >= list.length) return null;
    final d = list[at];
    if (d == null ||
        d.label != label ||
        d.vertex != vertex ||
        d.pixel != pixel ||
        d.stencilRef != stencilRef ||
        !_sameState(d.state, state)) {
      return null;
    }
    final v = d.viewport, n = viewport;
    if (v[0] != n[0] ||
        v[1] != n[1] ||
        v[2] != n[2] ||
        v[3] != n[3] ||
        v[4] != n[4] ||
        v[5] != n[5]) {
      return null;
    }
    final vr = d.vertexResources, pr = d.pixelResources;
    if (!_sameBlocks(vr.blocks, vsBlocks) ||
        !_sameBlocks(pr.blocks, blocks) ||
        !_sameTextures(pr.textures, textures) ||
        !_sameSamplers(pr.samplers, samplers)) {
      return null;
    }
    _give(vr.blocks, vsBlocks, frameBlocks);
    _give(pr.blocks, blocks, frameBlocks);
    return d;
  }

  /// This frame's bytes for the kept blocks that are this keep's roles.
  void _give(
    Map<String, Uint8List> kept,
    Map<String, Uint8List> now,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    _withBlocks = now;
    _frameBlocks = frameBlocks;
    kept.forEach(_giveOne_);
    _withBlocks = null;
    _frameBlocks = null;
  }

  void _giveOne(String key, Uint8List a) {
    if (_ours.contains(a)) _frameBlocks![a] = _given[a] = _withBlocks![key]!;
  }

  /// Kept draw [d] again in a frame that did not offer it: its roles get
  /// the bytes they were last given. Only for a caller that knows [d]'s
  /// blocks are what they were (a text whose inputs held), whose bytes
  /// nothing writes again.
  void giveAgain(DrawPlan d, Map<Uint8List, Uint8List> frameBlocks) {
    _frameBlocks = frameBlocks;
    d.vertexResources.blocks.forEach(_againOne_);
    d.pixelResources.blocks.forEach(_againOne_);
    _frameBlocks = null;
  }

  void _againOne(String key, Uint8List a) {
    if (_given[a] case final b?) _frameBlocks![a] = b;
  }

  late final _againOne_ = _againOne;

  // The comparisons walk the kept map by forEach, through tear-offs made
  // once (a key walk made two iterator objects per map, four maps a draw a
  // frame; perf): with the lengths equal, every kept key found the same
  // means the maps are. Their other side and result in fields.
  Map<String, Uint8List>? _withBlocks;
  Map<Uint8List, Uint8List>? _frameBlocks;
  Map<String, TextureRef>? _withTextures;
  Map<int, SamplerState>? _withSamplers;
  bool _same = true;
  late final _giveOne_ = _giveOne;
  late final _blockOne_ = _blockOne;
  late final _textureOne_ = _textureOne;
  late final _samplerOne_ = _samplerOne;

  /// [now] as the new draw at [at] in pass [pass] holds them (stage [stage]):
  /// a block that changed since the slot's last draw, or was already a role
  /// of it, as the slot's role (its bytes given in [frameBlocks]); another
  /// role as it is; the rest as copies.
  Map<String, Uint8List> blocks(
    String pass,
    int at,
    String stage,
    Map<String, Uint8List> now,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    final list = _byPass[pass];
    final last = list == null || at >= list.length ? null : list[at];
    final had = last == null
        ? null
        : stage == 'vs'
        ? last.vertexResources.blocks
        : last.pixelResources.blocks;
    final out = <String, Uint8List>{};
    for (final key in now.keys) {
      final b = now[key]!;
      final a = had?[key];
      if (FrameRole.of(b) != null) {
        out[key] = b;
      } else if (a != null && (_ours.contains(a) || !_sameBytes(a, b))) {
        final role = FrameRole('screen $_id $pass $at $stage $key');
        _ours.add(role.block);
        frameBlocks[role.block] = _given[role.block] = b;
        out[key] = role.block;
      } else {
        out[key] = Uint8List.fromList(b);
      }
    }
    return out;
  }

  /// [d] (just made) as the draw at [at] in pass [pass]: the slot's last
  /// draw when [d] draws the same, else [d]'s own copy kept for the slot
  /// (its changing blocks bound by the slot's roles, its inline geometry
  /// copied). For draws made outside a builder's screen draws.
  DrawPlan kept(
    String pass,
    int at,
    DrawPlan d,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    final g = d.geometry;
    final v = d.viewport;
    final list = _byPass[pass];
    final last = list == null || at >= list.length ? null : list[at];
    if (last != null &&
        _sameGeometry(last.geometry, g) &&
        _sameStorage(last.pixelResources.storage, d.pixelResources.storage) &&
        _sameStorage(last.vertexResources.storage, d.vertexResources.storage) &&
        _sameTextures(
          last.vertexResources.textures,
          d.vertexResources.textures,
        ) &&
        _sameSamplers(
          last.vertexResources.samplers,
          d.vertexResources.samplers,
        ) &&
        match(
              pass,
              at,
              d.label,
              d.vertex,
              d.pixel,
              d.state,
              _viewport
                ..[0] = v[0]
                ..[1] = v[1]
                ..[2] = v[2]
                ..[3] = v[3]
                ..[4] = v[4]
                ..[5] = v[5],
              d.vertexResources.blocks,
              d.pixelResources.blocks,
              d.pixelResources.textures,
              d.pixelResources.samplers,
              d.stencilRef,
              frameBlocks,
            ) !=
            null) {
      return last;
    }
    StageResources stage(StageResources r, String name) => StageResources(
      blocks: blocks(pass, at, name, r.blocks, frameBlocks),
      textures: {...r.textures},
      samplers: {...r.samplers},
      storage: {...r.storage},
    );
    final made = DrawPlan(
      label: d.label,
      vertex: d.vertex,
      pixel: d.pixel,
      geometry: switch (g) {
        InlineGeometry() => InlineGeometry(
          Uint8List.fromList(g.bytes),
          g.stride,
          g.registers,
          g.vertexCount,
          instances: g.instances,
          indices: switch (g.indices) {
            final i? => Uint8List.fromList(i),
            null => null,
          },
        ),
        _ => g,
      },
      state: d.state,
      viewport: [...v],
      vertexResources: stage(d.vertexResources, 'vs'),
      pixelResources: stage(d.pixelResources, 'ps'),
      stencilRef: d.stencilRef,
    );
    keep(pass, at, made);
    return made;
  }

  static bool _sameGeometry(DrawGeometry a, DrawGeometry b) {
    if (identical(a, b)) return true;
    return switch ((a, b)) {
      (final InlineGeometry x, final InlineGeometry y) =>
        x.stride == y.stride &&
            x.vertexCount == y.vertexCount &&
            x.instances == y.instances &&
            _sameRegisters(x.registers, y.registers) &&
            _sameBytes(x.bytes, y.bytes) &&
            (x.indices == null
                ? y.indices == null
                : y.indices != null && _sameBytes(x.indices!, y.indices!)),
      (final ScreenGeometry x, final ScreenGeometry y) =>
        x.vertexCount == y.vertexCount && x.instances == y.instances,
      // Mesh draws kept by label (a builder may keep its own by their
      // inputs instead): the same mesh and range, without indirect
      // arguments or streams.
      (final DrawMeshGeometry x, final DrawMeshGeometry y) =>
        x.mesh == y.mesh &&
            x.ibuffer == y.ibuffer &&
            x.firstIndex == y.firstIndex &&
            x.indexCount == y.indexCount &&
            x.instances == y.instances &&
            x.indirect == null &&
            y.indirect == null &&
            x.streams.isEmpty &&
            y.streams.isEmpty,
      _ => false,
    };
  }

  static bool _sameRegisters(
    Map<int, (String, int)> a,
    Map<int, (String, int)> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final key in b.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  // Walked by forEach through a function made once (perf: two iterator
  // objects per storage map compared).
  static bool _sameStorage(
    Map<String, StorageRef> a,
    Map<String, StorageRef> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    _storageWith = a;
    _storageOk = true;
    b.forEach(_storageOne);
    _storageWith = null;
    return _storageOk;
  }

  static Map<String, StorageRef>? _storageWith;
  static var _storageOk = true;

  static void _storageOne(String key, StorageRef y) {
    if (!_storageOk) return;
    final x = _storageWith![key];
    if (identical(x, y)) return;
    final bool same;
    if (x is BufferRef && y is BufferRef) {
      same = _sameRef(x, y);
    } else if (x is ImageRef && y is ImageRef) {
      same = x.target == y.target && x.mip == y.mip && x.layer == y.layer;
    } else if (x is InlineBuffer && y is InlineBuffer) {
      same = x.format == y.format && _sameBytes(x.bytes, y.bytes);
    } else {
      same = false;
    }
    if (!same) _storageOk = false;
  }

  /// Dispatches kept by name and occurrence ([keptDispatch]).
  final _dispatches = <String, List<DispatchPlan?>>{};

  /// [d] (just made): the dispatch of its name last frame when it runs the
  /// same (shader, groups, indirect arguments, block bytes, textures,
  /// samplers and storage), else [d]'s own copy kept under its name (its
  /// changing blocks bound by roles of the name, as a draw slot's).
  DispatchPlan keptDispatch(
    DispatchPlan d,
    int occurrence,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    final slot = 'dispatch ${d.name}';
    final kept = _dispatches[d.name] ??= [];
    while (kept.length <= occurrence) {
      kept.add(null);
    }
    final last = kept[occurrence];
    final r = d.resources;
    final hit = matchDispatch(
      d.name,
      occurrence,
      d.shader,
      d.groups,
      d.indirect,
      r.blocks,
      r.textures,
      r.samplers,
      r.storage,
      frameBlocks,
    );
    if (hit != null) return hit;
    // The blocks against the kept dispatch's, under a slot of its own.
    if (last != null) keep(slot, occurrence, _asDraw(last));
    final made = DispatchPlan(
      d.name,
      d.shader,
      [...d.groups],
      StageResources(
        blocks: blocks(slot, occurrence, 'cs', r.blocks, frameBlocks),
        textures: {...r.textures},
        samplers: {...r.samplers},
        storage: {
          for (final MapEntry(:key, :value) in r.storage.entries)
            key: value is InlineBuffer
                ? InlineBuffer(
                    Uint8List.fromList(value.bytes),
                    format: value.format,
                  )
                : value,
        },
      ),
      indirect: d.indirect,
    );
    kept[occurrence] = made;
    keep(slot, occurrence, _asDraw(made));
    return made;
  }

  /// The dispatch of [name] at [occurrence] last frame when one made of
  /// these would run the same ([keptDispatch]'s comparison, without the
  /// dispatch made: a builder's dispatch from its parts), its role blocks given this
  /// frame's bytes; else null.
  DispatchPlan? matchDispatch(
    String name,
    int occurrence,
    String shader,
    List<int> groups,
    BufferRef? indirect,
    Map<String, Uint8List> blocks,
    Map<String, TextureRef> textures,
    Map<int, SamplerState> samplers,
    Map<String, StorageRef> storage,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    final kept = _dispatches[name];
    if (kept == null || occurrence >= kept.length) return null;
    final last = kept[occurrence];
    if (last == null) return null;
    final lr = last.resources;
    if (last.shader == shader &&
        _sameInts(last.groups, groups) &&
        (last.indirect == null
            ? indirect == null
            : indirect != null && _sameRef(last.indirect!, indirect)) &&
        _sameBlocks(lr.blocks, blocks) &&
        _sameTextures(lr.textures, textures) &&
        _sameSamplers(lr.samplers, samplers) &&
        _sameStorage(lr.storage, storage)) {
      _give(lr.blocks, blocks, frameBlocks);
      return last;
    }
    return null;
  }

  /// A dispatch's blocks as a draw slot holds them ([blocks] reads a
  /// slot's last draw's pixel stage for stage 'cs').
  static DrawPlan _asDraw(DispatchPlan d) => DrawPlan(
    vertex: '',
    pixel: null,
    geometry: const ScreenGeometry(0),
    state: const DrawState(),
    viewport: const [],
    vertexResources: StageResources(),
    pixelResources: d.resources,
  );

  static bool _sameInts(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Keeps [d] as the draw at [at] in pass [pass].
  void keep(String pass, int at, DrawPlan d) {
    final list = _byPass[pass] ??= [];
    while (list.length <= at) {
      list.add(null);
    }
    list[at] = d;
  }

  bool _sameBlocks(Map<String, Uint8List> kept, Map<String, Uint8List> now) {
    if (kept.length != now.length) return false;
    _withBlocks = now;
    _same = true;
    kept.forEach(_blockOne_);
    _withBlocks = null;
    return _same;
  }

  void _blockOne(String key, Uint8List a) {
    if (!_same) return;
    final b = _withBlocks![key];
    // The slot's role takes any bytes; a role the caller gives doesn't.
    if (b == null ||
        (_ours.contains(a) ? FrameRole.of(b) != null : !_sameBytes(a, b))) {
      _same = false;
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    // A role's block is its own object: only the same one matches.
    if (FrameRole.of(a) != null || FrameRole.of(b) != null) return false;
    final n = a.length;
    if (n != b.length) return false;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _sameTextures(
    Map<String, TextureRef> kept,
    Map<String, TextureRef> now,
  ) {
    if (kept.length != now.length) return false;
    _withTextures = now;
    _same = true;
    kept.forEach(_textureOne_);
    _withTextures = null;
    return _same;
  }

  void _textureOne(String key, TextureRef a) {
    if (!_same) return;
    final b = _withTextures![key];
    if (b == null || !_sameTexture(a, b)) _same = false;
  }

  static bool _sameTexture(TextureRef a, TextureRef b) {
    if (identical(a, b)) return true;
    return switch ((a, b)) {
      (final TargetTexture x, final TargetTexture y) =>
        x.target == y.target &&
            x.mip == y.mip &&
            x.mips == y.mips &&
            x.layer == y.layer &&
            x.layers == y.layers &&
            x.srgb == y.srgb,
      (final FileTexture x, final FileTexture y) =>
        x.stem == y.stem && x.srgb == y.srgb,
      (final BufferTexture x, final BufferTexture y) =>
        x.format == y.format && _sameBytes(x.bytes, y.bytes),
      (final BufferTextureRef x, final BufferTextureRef y) => _sameRef(
        x.ref,
        y.ref,
      ),
      // A constant texture is the codec's by identity: only the same one.
      _ => false,
    };
  }

  static bool _sameRef(BufferRef a, BufferRef b) =>
      identical(a, b) ||
      (a.buffer == b.buffer &&
          a.offset == b.offset &&
          a.size == b.size &&
          a.format == b.format);

  bool _sameSamplers(Map<int, SamplerState> kept, Map<int, SamplerState> now) {
    if (kept.length != now.length) return false;
    _withSamplers = now;
    _same = true;
    kept.forEach(_samplerOne_);
    _withSamplers = null;
    return _same;
  }

  void _samplerOne(int key, SamplerState a) {
    if (!_same) return;
    final b = _withSamplers![key];
    if (b == null || !_sameSampler(a, b)) _same = false;
  }

  static bool _sameSampler(SamplerState a, SamplerState b) {
    if (identical(a, b)) return true;
    if (a.minLinear != b.minLinear ||
        a.magLinear != b.magLinear ||
        a.mipLinear != b.mipLinear ||
        a.anisotropy != b.anisotropy ||
        a.compare != b.compare ||
        a.minLod != b.minLod ||
        a.maxLod != b.maxLod ||
        a.lodBias != b.lodBias ||
        a.border != b.border ||
        a.address.length != b.address.length) {
      return false;
    }
    for (var i = 0; i < a.address.length; i++) {
      if (a.address[i] != b.address[i]) return false;
    }
    return true;
  }

  static bool _sameState(DrawState a, DrawState b) {
    if (identical(a, b)) return true;
    if (a.cull != b.cull ||
        a.frontCounterClockwise != b.frontCounterClockwise ||
        a.depthTest != b.depthTest ||
        a.depthWrite != b.depthWrite ||
        a.depthFunc != b.depthFunc ||
        a.depthBias != b.depthBias ||
        a.slopeScaledDepthBias != b.slopeScaledDepthBias ||
        a.depthBiasClamp != b.depthBiasClamp ||
        a.topology != b.topology ||
        !_sameStencil(a.stencil, b.stencil) ||
        a.blends.length != b.blends.length) {
      return false;
    }
    for (var i = 0; i < a.blends.length; i++) {
      if (!_sameBlend(a.blends[i], b.blends[i])) return false;
    }
    return true;
  }

  static bool _sameStencil(Stencil? a, Stencil? b) =>
      identical(a, b) ||
      (a != null &&
          b != null &&
          a.func == b.func &&
          a.passOp == b.passOp &&
          a.readMask == b.readMask &&
          a.writeMask == b.writeMask);

  static bool _sameBlend(Blend a, Blend b) =>
      identical(a, b) ||
      (a.enabled == b.enabled &&
          a.writeMask == b.writeMask &&
          _sameStrings(a.color, b.color) &&
          _sameStrings(a.alpha, b.alpha));

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
