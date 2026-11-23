import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:prismarine_kept/prismarine_kept.dart';

import 'frame_plan.dart';
import 'plan_codec.dart';

/// Reads what an [PlanWriter] wrote, message by message in the order
/// written: every message is read, since each may name objects the next
/// ones refer to.
class PlanReader {
  final _objects = <Object?>[];
  final _table = PlanIds();
  late PlanMessage _m;
  int _i = 0, _d = 0;

  /// The writer's string table (PlanWriter: strings by id).
  final _strings = <String>[];

  /// The plan (null: no camera showed) and the draws of [m].
  (FramePlan?, List<DrawPlan>) read(PlanMessage m) {
    _m = m;
    _i = _d = 0;
    if (_int() != 0) _strings.clear();
    _strings.addAll(m.strings);
    final plan = _int() == 0 ? null : _plan();
    final draws = [for (var n = _int(); n > 0; n--) _draw()];
    for (final id in m.dropped) {
      _objects[id] = null;
      _table.free(id);
    }
    return (plan, draws);
  }

  /// Each pass's rows as the writer sent them, by pass and row id, in the
  /// order they came, and the set last made of them.
  final _rowTables = <String, LinkedHashMap<int, DrawPlan>>{};
  final _rowSets = <String, RowSet>{};

  /// A pass's rows (PlanWriter._rows): its table with this message's
  /// changes, as a set made again only when something changed.
  RowSet? _rows(String pass) {
    final mode = _int();
    if (mode == 0) return null;
    final table = _rowTables[pass] ??= LinkedHashMap();
    final bounds = _rowBounds[pass] ??= {};
    if (mode == 2) {
      table.clear();
      bounds.clear();
    }
    var changed = mode == 2;
    final ids = _rowIds..clear();
    for (var n = _int(); n > 0; n--) {
      final id = _int();
      table[id] = _draw();
      ids.add(id);
      changed = true;
    }
    for (var n = _int(); n > 0; n--) {
      final id = _int();
      table.remove(id);
      bounds.remove(id);
      changed = true;
    }
    final hasBounds = _int() == 1;
    if (hasBounds) {
      // Filled directly (perf: a list of boxed doubles per row).
      for (var i = 0; i < ids.length; i++) {
        final b = bounds[ids[i]] = Float32List(10);
        for (var k = 0; k < 10; k++) {
          b[k] = _double();
        }
      }
    }
    final n = _int();
    Float32List? params;
    if (n >= 0) {
      params = Float32List(n);
      for (var k = 0; k < n; k++) {
        params[k] = _double();
      }
    }
    var had = _rowSets[pass];
    if (had == null || changed) {
      final keys = table.keys.toList(growable: false);
      Float32List? all;
      if (hasBounds) {
        all = Float32List(keys.length * 10);
        for (var i = 0; i < keys.length; i++) {
          all.setAll(i * 10, bounds[keys[i]]!);
        }
      }
      had = RowSet(keys, table.values.toList(growable: false), bounds: all);
    }
    return _rowSets[pass] = params == null
        ? had
        : (RowSet(had.ids, had.plans, bounds: had.bounds, params: params)
            ..keepDrawsOf(had));
  }

  final _rowIds = KeptList<int>();

  /// Each pass's rows' bounds as sent, by pass and row id.
  final _rowBounds = <String, Map<int, Float32List>>{};

  /// Objects in the table now (tests).
  int get tableSize => _objects.where((o) => o != null).length;

  int _int() => _m.ints[_i++];
  double _double() => _m.doubles[_d++];
  String _string() => _strings[_int()];
  bool _flag() => _int() != 0;

  String? _stringOrNull() {
    final k = _int();
    return k < 0 ? null : _strings[k];
  }

  int? _intOrNull() => _flag() ? _int() : null;

  List<double>? _doubleList() {
    final n = _int();
    if (n < 0) return null;
    return [for (var k = 0; k < n; k++) _double()];
  }

  List<String> _stringList() => [for (var n = _int(); n > 0; n--) _string()];

  T _keep<T extends Object>(T o) {
    final id = _table.take();
    while (_objects.length <= id) {
      _objects.add(null);
    }
    _objects[id] = o;
    return o;
  }

  /// The next value's tag: for null ([tagNull]) and an object read before
  /// ([tagRef]) the value is [_found]; any other tag's value is defined by
  /// the reader's `…Of(tag)` and passed to [_done]. Without a closure per
  /// value (each read allocated one and its context; perf).
  int _tag() {
    final tag = _int();
    _found = tag == tagRef ? _objects[_int()] : null;
    return tag;
  }

  Object? _found;

  /// [o], defined for [tag], kept by id when it is of a kind the writer
  /// keeps.
  T _done<T extends Object>(int tag, T o) => switch (tag) {
    tagBytes ||
    tagNative ||
    tagRole ||
    tagSampler ||
    tagFile ||
    tagConstant ||
    tagRegisters => _keep(o),
    _ => o,
  };

  Uint8List? _block() {
    final tag = _tag();
    if (tag <= tagRef) return _found as Uint8List?;
    return _done(tag, _blockOf(tag));
  }

  Uint8List _blockOf(int tag) {
    if (tag == tagRole) return FrameRole(_string()).block;
    if (tag == tagNative) {
      // In the writer's store, read in place (no copy, no finalizer: the
      // writer frees it once released).
      final address = _int(), length = _int();
      return Pointer<Uint8>.fromAddress(address).asTypedList(length);
    }
    _expect(tag, tagBytes);
    return _m.bytes[_int()];
  }

  void _expect(int tag, int want) {
    if (tag != want) {
      throw StateError('s2 plan message: tag $tag where $want belongs');
    }
  }

  /// The last plan's targets (a plan with the same ones names them so).
  Map<String, TargetSpec>? _lastTargets;

  /// The plan's buffers: last plan's map again while every entry is the
  /// same (its name, size and initial bytes' object; perf: a map and a
  /// spec per buffer each frame).
  Map<String, BufferSpec> _buffers() {
    final n = _int();
    final names = _bufferNames..clear(), sizes = _bufferSizes..clear();
    final initials = _bufferInitials..clear();
    // A size carries the read-back flag in its low bit.
    for (var k = 0; k < n; k++) {
      names.add(_string());
      initials.add(_block());
      sizes.add(_int());
    }
    final last = _lastBuffers;
    if (last != null && last.length == n) {
      var k = 0, same = true;
      for (final name in last.keys) {
        final spec = last[name]!;
        if (!identical(name, names[k]) ||
            spec.size << 1 | (spec.readBack ? 1 : 0) != sizes[k] ||
            !identical(spec.initial, initials[k])) {
          same = false;
          break;
        }
        k++;
      }
      if (same) return last;
    }
    final out = <String, BufferSpec>{
      for (var k = 0; k < n; k++)
        names[k]: BufferSpec(
          sizes[k] >> 1,
          initial: initials[k],
          readBack: sizes[k] & 1 != 0,
        ),
    };
    return _lastBuffers = out;
  }

  Map<String, BufferSpec>? _lastBuffers;
  final _bufferNames = KeptList<String>(), _bufferSizes = KeptList<int>();
  final _bufferInitials = KeptList<Uint8List?>();

  FramePlan _plan() {
    final count = _int();
    final Map<String, TargetSpec> targets;
    if (count < 0) {
      // The writer's last targets again: the same map object.
      targets = _lastTargets!;
    } else {
      targets = <String, TargetSpec>{};
      for (var n = count; n > 0; n--) {
        final name = _string();
        targets[name] = _targetSpec();
      }
    }
    _lastTargets = targets;
    final buffers = _buffers();
    // Three role maps in turn, as the writer's: a plan's map holds until
    // the third plan after it (perf: a map and an entry per role a frame).
    final frameBlocks = _roleMaps[_plans++ % 3]..clear();
    for (var n = _int(); n > 0; n--) {
      final role = _block()!;
      frameBlocks[role] = _block()!;
    }
    // The stamps in the role maps' turn.
    final retained = _retainMaps[(_plans - 1) % 3]..clear();
    for (var n = _int(); n > 0; n--) {
      final pass = _string();
      retained[pass] = _int();
    }
    // Read into scratch; last plan's list again while it holds the same
    // passes (perf: a list of a hundred passes a frame).
    final scratch = _passScratch..clear();
    for (var n = _int(), k = 0; k < n; k++) {
      scratch.add(_pass(k));
    }
    final passes = _lastPasses = keptCopyOf(_lastPasses, scratch);
    return FramePlan(
      targets,
      passes,
      buffers: buffers,
      frameBlocks: frameBlocks,
      retained: retained,
    );
  }

  /// A kept pass's [draws] read whole in place (shortened or grown).
  void _reshapeDraws(List<DrawPlan> draws) {
    final n = _int();
    if (draws.length > n) draws.length = n;
    for (var k = 0; k < n; k++) {
      final d = _draw();
      if (k < draws.length) {
        draws[k] = d;
      } else {
        draws.add(d);
      }
    }
  }

  final _roleMaps = [
    KeptMap<Uint8List, Uint8List>.identity(),
    KeptMap<Uint8List, Uint8List>.identity(),
    KeptMap<Uint8List, Uint8List>.identity(),
  ];
  // alloc: once per reader, as its three maps
  final _retainMaps = [
    // alloc: once per reader
    KeptMap<String, int>(),
    // alloc: once per reader
    KeptMap<String, int>(),
    // alloc: once per reader
    KeptMap<String, int>(),
  ];
  int _plans = 0;
  final _passScratch = KeptList<PassPlan>();
  List<PassPlan>? _lastPasses;

  PassPlan _pass(int _) {
    final tag = _int();
    if (tag == tagRef) return _objects[_int()]! as PassPlan;
    if (tag == tagRenderEdit) {
      // The kept pass with its changed draws put in place; its runner
      // caches see the new version.
      final pass = _objects[_int()]! as RenderPassPlan;
      for (var k = _int(); k > 0; k--) {
        final at = _int();
        pass.draws[at] = _draw();
      }
      pass.version++;
      return pass;
    }
    if (tag == tagRenderRows) {
      // The kept pass with its draws whole and its rows' changes, written
      // in place, its runner caches seeing the new version.
      final pass = _objects[_int()]! as RenderPassPlan;
      _reshapeDraws(pass.draws);
      pass
        ..rows = _rows(pass.name)
        ..version += 1;
      return pass;
    }
    if (tag == tagRenderReshape) {
      // The kept pass with its draws whole: written in place (shortened
      // or grown), its runner caches seeing the new version.
      final pass = _objects[_int()]! as RenderPassPlan;
      _reshapeDraws(pass.draws);
      pass.version++;
      return pass;
    }
    final name = _string();
    if (tag == tagRender || tag == tagRenderKept) {
      final colors = [for (var k = _int(); k > 0; k--) _attachment()!];
      final depth = _attachment();
      final draws = [for (var k = _int(); k > 0; k--) _draw()];
      final r = RenderPassPlan(name, colors, depth, draws)..rows = _rows(name);
      return tag == tagRenderKept ? _keep(r) : r;
    }
    if (tag != tagDispatchKept) _expect(tag, tagDispatch);
    final shader = _string();
    final groups = [for (var k = _int(); k > 0; k--) _int()];
    final resources = _resources();
    final c = DispatchPlan(
      name,
      shader,
      groups,
      resources,
      indirect: _bufferRef(),
    );
    return tag == tagDispatchKept ? _keep(c) : c;
  }

  TargetSpec _targetSpec() {
    final tag = _tag();
    if (tag <= tagRef) return _found as TargetSpec;
    return _done(tag, _targetSpecOf(tag));
  }

  TargetSpec _targetSpecOf(int tag) {
    _expect(tag, tagTargetSpec);
    final w = _int(), h = _int();
    final format = _string();
    final layers = _int(), mips = _int(), samples = _int(), bits = _int();
    return TargetSpec(
      w,
      h,
      format,
      layers: layers,
      mips: mips,
      samples: samples,
      storage: bits & 1 != 0,
      volume: bits & 2 != 0,
      initial: bits & 4 != 0 ? _block() : null,
    );
  }

  Attachment? _attachment() {
    final tag = _tag();
    if (tag <= tagRef) return _found as Attachment?;
    return _done(tag, _attachmentOf(tag));
  }

  Attachment _attachmentOf(int tag) {
    _expect(tag, tagAttachment);
    final target = _string();
    final mip = _int(), layer = _int();
    final srgb = _flag();
    final clear = _doubleList();
    final depth = _flag() ? _double() : null;
    return Attachment(
      target,
      mip: mip,
      layer: layer,
      srgb: srgb,
      clear: clear,
      clearDepth: depth,
      clearStencil: _intOrNull(),
    );
  }

  DrawPlan _draw() {
    final tag = _int();
    if (tag == tagRef) return _objects[_int()]! as DrawPlan;
    if (tag != tagDrawKept) _expect(tag, tagDraw);
    final vertex = _string();
    final pixel = _stringOrNull();
    final geometry = _geometry();
    final state = _state();
    final viewport = _doubleList()!;
    final vr = _resources(), pr = _resources();
    final draw = DrawPlan(
      vertex: vertex,
      pixel: pixel,
      geometry: geometry,
      state: state,
      viewport: viewport,
      vertexResources: vr,
      pixelResources: pr,
      label: _string(),
      stencilRef: _int(),
    );
    return tag == tagDrawKept ? _keep(draw) : draw;
  }

  StageResources _resources() {
    // An empty kind shares one constant map (nothing writes a read plan's
    // resources): most draws bind no storage and few samplers, and four
    // maps a draw were a frame's garbage (perf).
    var n = _int();
    final blocks = n == 0 ? const <String, Uint8List>{} : <String, Uint8List>{};
    for (; n > 0; n--) {
      final name = _string();
      blocks[name] = _block()!;
    }
    n = _int();
    final textures = n == 0
        ? const <String, TextureRef>{}
        : <String, TextureRef>{};
    for (; n > 0; n--) {
      final name = _string();
      textures[name] = _texture();
    }
    n = _int();
    final samplers = n == 0
        ? const <int, SamplerState>{}
        : <int, SamplerState>{};
    for (; n > 0; n--) {
      final slot = _int();
      samplers[slot] = _sampler();
    }
    n = _int();
    final storage = n == 0
        ? const <String, StorageRef>{}
        : <String, StorageRef>{};
    for (; n > 0; n--) {
      final name = _string();
      storage[name] = _storage();
    }
    return StageResources(
      blocks: blocks,
      textures: textures,
      samplers: samplers,
      storage: storage,
    );
  }

  TextureRef _texture() {
    final tag = _tag();
    if (tag <= tagRef) return _found as TextureRef;
    return _done(tag, _textureOf(tag));
  }

  TextureRef _textureOf(int tag) => switch (tag) {
    tagFile => FileTexture(_string(), srgb: _flag()),
    tagTarget => TargetTexture(
      _string(),
      mip: _int(),
      mips: _int(),
      layer: _int(),
      layers: _int(),
      srgb: _flag(),
    ),
    tagBufferTex => BufferTexture(_block()!, _string()),
    tagConstant => _constantTexture(),
    tagBufferTexRef => BufferTextureRef(_bufferRef()!),
    _ => throw StateError('s2 plan message: tag $tag is no texture'),
  };

  ConstantTexture _constantTexture() {
    final texel = _block()!;
    final format = _string();
    final type = _string();
    final w = _int(), h = _int();
    return ConstantTexture(
      format,
      texel,
      type: type,
      width: w == 0 ? null : w,
      height: h == 0 ? null : h,
    );
  }

  StorageRef _storage() {
    final tag = _tag();
    if (tag <= tagRef) return _found as StorageRef;
    return _done(tag, _storageOf(tag));
  }

  StorageRef _storageOf(int tag) => switch (tag) {
    tagBufferRef => _bufferRefFields(),
    tagInlineBuffer => InlineBuffer(_block()!, format: _stringOrNull()),
    tagImage => ImageRef(_string(), mip: _int(), layer: _int()),
    _ => throw StateError('s2 plan message: tag $tag is no storage'),
  };

  BufferRef? _bufferRef() {
    final tag = _tag();
    if (tag <= tagRef) return _found as BufferRef?;
    return _done(tag, _bufferRefOf(tag));
  }

  BufferRef _bufferRefOf(int tag) {
    _expect(tag, tagBufferRef);
    return _bufferRefFields();
  }

  BufferRef _bufferRefFields() {
    final buffer = _string();
    final offset = _int();
    final size = _intOrNull();
    return BufferRef(
      buffer,
      offset: offset,
      size: size,
      format: _stringOrNull(),
    );
  }

  SamplerState _sampler() {
    final tag = _tag();
    if (tag <= tagRef) return _found as SamplerState;
    return _done(tag, _samplerOf(tag));
  }

  SamplerState _samplerOf(int tag) {
    _expect(tag, tagSampler);
    final bits = _int();
    final address = _stringList();
    final anisotropy = _int();
    final compare = _stringOrNull();
    final minLod = _double(), maxLod = _double(), lodBias = _double();
    return SamplerState(
      minLinear: bits & 1 != 0,
      magLinear: bits & 2 != 0,
      mipLinear: bits & 4 != 0,
      address: address,
      anisotropy: anisotropy,
      compare: compare,
      minLod: minLod,
      maxLod: maxLod,
      lodBias: lodBias,
      border: _string(),
    );
  }

  DrawState _state() {
    final tag = _tag();
    if (tag <= tagRef) return _found as DrawState;
    return _done(tag, _stateOf(tag));
  }

  DrawState _stateOf(int tag) {
    _expect(tag, tagState);
    final blends = [for (var n = _int(); n > 0; n--) _blend()];
    final stencil = _stencil();
    final cull = _string();
    final bits = _int();
    final depthFunc = _string();
    final bias = _double(), slope = _double(), clamp = _double();
    return DrawState(
      cull: cull,
      frontCounterClockwise: bits & 1 != 0,
      depthTest: bits & 2 != 0,
      depthWrite: bits & 4 != 0,
      depthFunc: depthFunc,
      blends: blends,
      depthBias: bias,
      slopeScaledDepthBias: slope,
      depthBiasClamp: clamp,
      topology: _string(),
      stencil: stencil,
    );
  }

  Blend _blend() {
    final tag = _tag();
    if (tag <= tagRef) return _found as Blend;
    return _done(tag, _blendOf(tag));
  }

  Blend _blendOf(int tag) {
    _expect(tag, tagBlend);
    final enabled = _flag();
    final color = _stringList(), alpha = _stringList();
    return Blend(
      enabled: enabled,
      color: color,
      alpha: alpha,
      writeMask: _int(),
    );
  }

  Stencil? _stencil() {
    final tag = _tag();
    if (tag <= tagRef) return _found as Stencil?;
    return _done(tag, _stencilOf(tag));
  }

  Stencil _stencilOf(int tag) {
    _expect(tag, tagStencil);
    final func = _string(), passOp = _string();
    return Stencil(
      func: func,
      passOp: passOp,
      readMask: _int(),
      writeMask: _int(),
    );
  }

  DrawGeometry _geometry() {
    final tag = _tag();
    if (tag <= tagRef) return _found as DrawGeometry;
    return _done(tag, _geometryOf(tag));
  }

  DrawGeometry _geometryOf(int tag) => switch (tag) {
    tagMesh => _mesh(),
    tagInline => _inlineGeometry(),
    tagScreen => ScreenGeometry(_int(), instances: _int()),
    _ => throw StateError('s2 plan message: tag $tag is no geometry'),
  };

  InlineGeometry _inlineGeometry() {
    final bytes = _block()!;
    final indices = _block();
    final registers = _registers();
    final stride = _int(), count = _int();
    return InlineGeometry(
      bytes,
      stride,
      registers,
      count,
      instances: _int(),
      indices: indices,
    );
  }

  DrawMeshGeometry _mesh() {
    final mesh = _string();
    final ibuffer = _int(), first = _int(), count = _int();
    final instances = _int();
    final indirect = _bufferRef();
    final streams = <int, (BufferRef, int, String)>{};
    for (var n = _int(); n > 0; n--) {
      final register = _int();
      final ref = _bufferRef()!;
      final stride = _int();
      streams[register] = (ref, stride, _string());
    }
    return DrawMeshGeometry(
      mesh,
      ibuffer,
      first,
      count,
      instances: instances,
      indirect: indirect,
      streams: streams,
    );
  }

  Map<int, (String, int)> _registers() {
    final tag = _tag();
    if (tag <= tagRef) return _found as Map<int, (String, int)>;
    return _done(tag, _registersOf(tag));
  }

  Map<int, (String, int)> _registersOf(int tag) {
    _expect(tag, tagRegisters);
    final out = <int, (String, int)>{};
    for (var n = _int(); n > 0; n--) {
      final register = _int();
      final format = _string();
      out[register] = (format, _int());
    }
    return out;
  }
}
