import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_render/prismarine_render.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

import 'pbr_settings.dart';

/// The shaders of the renderer: a library loaded from a shader bundle and
/// the interface of each shader by id.
class PbrShaderBundle {
  PbrShaderBundle(this.library, this.records);

  /// Loads the gzip-compressed bundle [bundle] and the interfaces in the
  /// JSON text [records], as the bundle tool of the package writes them.
  static Future<PbrShaderBundle> load(Uint8List bundle, String records) async {
    final bytes = Uint8List.fromList(gzip.decode(bundle));
    final lib = await gpu.ShaderLibrary.fromBytes(ByteData.sublistView(bytes));
    if (lib == null) {
      throw StateError('the shader bundle did not load on this engine');
    }
    final json = (jsonDecode(records) as Map).cast<String, Object?>();
    return PbrShaderBundle(lib, {
      for (final MapEntry(:key, :value) in json.entries)
        key: ShaderRecord((value as Map).cast<String, Object?>(), null),
    });
  }

  final gpu.ShaderLibrary library;
  final Map<String, ShaderRecord> records;
}

/// The shaders that the frame runner uses besides the plan's own.
const pbrRunnerShaders = RunnerShaders(
  nullPixel: PbrShaderIds.nullPixel,
  depthClampPixel: PbrShaderIds.nullPixel,
  stencilCopyVertex: '',
  stencilCopyPixel: '',
);

/// The render assets of the renderer: its shaders and the meshes and
/// textures of its scenes by stem. A texture stem has the form
/// `<scene>:<image>` and a mesh stem `<scene>:<mesh>:<primitive>`, with the
/// scene by its key in [scenes].
class PbrAssets implements RenderAssets {
  PbrAssets(this.shaders, this.scenes);

  final PbrShaderBundle shaders;
  final Map<String, GpuScene> scenes;
  final _meshes = <String, _PrimitiveMesh>{};
  final _shaders = <String, gpu.Shader>{};

  @override
  bool hasShader(String id) => shaders.records.containsKey(id);

  @override
  ShaderRecord? shaderRecord(String id) => shaders.records[id];

  @override
  Future<void> loadShaders(Iterable<String> ids) async {}

  @override
  gpu.Shader shader(String id) => _shaders[id] ??=
      shaders.library[id] ?? (throw StateError('no shader $id'));

  (GpuScene, int) _image(String stem) {
    final at = stem.lastIndexOf(':');
    final scene = scenes[stem.substring(0, at)];
    if (scene == null) throw StateError('no scene for texture $stem');
    return (scene, int.parse(stem.substring(at + 1)));
  }

  @override
  Future<void> loadTextures(Iterable<String> stems) async {
    final sw = Stopwatch()..start();
    final byScene = <GpuScene, List<int>>{};
    for (final s in stems) {
      final (scene, image) = _image(s);
      (byScene[scene] ??= []).add(image);
    }
    await Future.wait([
      for (final MapEntry(:key, :value) in byScene.entries)
        key.loadTextures(value),
    ]);
    loadMs += sw.elapsedMicroseconds / 1000;
  }

  @override
  bool hasTexture(String stem) {
    final (scene, image) = _image(stem);
    return scene.hasImage(image);
  }

  @override
  gpu.Texture texture(String stem, {bool srgb = false}) {
    final sw = Stopwatch()..start();
    final (scene, image) = _image(stem);
    final t = scene.texture(image, srgb: srgb);
    loadMs += sw.elapsedMicroseconds / 1000;
    return t;
  }

  @override
  RenderMesh mesh(String stem) => _meshes[stem] ??= _makeMesh(stem);

  _PrimitiveMesh _makeMesh(String stem) {
    final parts = stem.split(':');
    final scene = scenes[parts[0]] ?? (throw StateError('no scene for $stem'));
    final p = scene.model.meshes[int.parse(parts[1])][int.parse(parts[2])];
    if (p == null) throw StateError('mesh $stem is not drawn');
    return _PrimitiveMesh(scene, p, droppedInputs);
  }

  @override
  final droppedInputs = <String, Set<String>>{};

  @override
  bool dropInput(String shaderId, String name) {
    if (!(droppedInputs[shaderId] ??= {}).add(name)) return false;
    for (final m in _meshes.values) {
      m._layouts.remove(shaderId);
    }
    return true;
  }

  @override
  RenderAssets atDirectory(String dir) =>
      throw UnsupportedError('the renderer has no asset directories');

  @override
  double loadMs = 0;

  @override
  String phase = 'record';

  @override
  final tally = LoadTally();

  @override
  void Function(String what, double ms, int bytes, String phase)? get onSlow =>
      null;

  @override
  String? tag;

  @override
  set warmFor(String? scene) {}

  @override
  set owners(int m) {}

  @override
  set onOwners(void Function(int owners)? f) {}

  @override
  int closed() => 0;

  @override
  int release(int since, {String? held, int keepOwners = 0}) => 0;

  // alloc-cold: a census line now and then.
  @override
  String get census =>
      'meshes ${_meshes.length}, shaders ${_shaders.length}, textures '
      '${scenes.values.fold(0, (n, s) => n + s.textureCount)}';
}

/// A primitive of a scene as the runner draws it: its index buffer and the
/// vertex layout of each shader.
class _PrimitiveMesh implements RenderMesh {
  _PrimitiveMesh(this.scene, this.primitive, this._dropped)
    : indexBuffers = [scene.views[primitive.indexView]!];

  final GpuScene scene;
  final ModelPrimitive primitive;
  final Map<String, Set<String>> _dropped;

  @override
  final List<gpu.DeviceBuffer> indexBuffers;

  final _layouts = <String, (gpu.VertexLayout, List<gpu.DeviceBuffer>)>{};

  @override
  (gpu.VertexLayout, List<gpu.DeviceBuffer>) layoutFor(
    String shaderId,
    ShaderRecord shader, {
    Iterable<int> skip = const [],
  }) {
    if (skip.isEmpty) {
      return _layouts[shaderId] ??= _layout(shaderId, shader, const {});
    }
    return _layout(shaderId, shader, skip.toSet());
  }

  (gpu.VertexLayout, List<gpu.DeviceBuffer>) _layout(
    String shaderId,
    ShaderRecord shader,
    Set<int> skip,
  ) {
    final dropped = _dropped[shaderId] ?? const {};
    final byView = <int, List<gpu.VertexAttribute>>{};
    final strides = <int, int>{};
    for (final a in shader.attributes) {
      if (dropped.contains(a.name) || skip.contains(a.register)) continue;
      final name = switch (a.semantic) {
        'TEXCOORD' ||
        'COLOR' ||
        'JOINTS' ||
        'WEIGHTS' => '${a.semantic}_${a.index}',
        final s => s,
      };
      final s = primitive.streams[name];
      if (s == null) {
        throw StateError('a primitive has no $name for $shaderId');
      }
      strides[s.view] = s.stride;
      (byView[s.view] ??= []).add(
        gpu.VertexAttribute(
          name: a.name,
          format: _format(s),
          offsetInBytes: s.offset,
        ),
      );
    }
    final views = byView.keys.toList();
    return (
      gpu.VertexLayout(
        buffers: [
          for (final v in views)
            gpu.VertexBuffer(
              strideInBytes: strides[v]!,
              attributes: byView[v]!,
            ),
        ],
      ),
      [for (final v in views) scene.views[v]!],
    );
  }

  static gpu.VertexFormat _format(ModelStream s) =>
      switch ((s.componentType, s.components, s.normalized)) {
        (5126, 2, _) => gpu.VertexFormat.float32x2,
        (5126, 3, _) => gpu.VertexFormat.float32x3,
        (5126, 4, _) => gpu.VertexFormat.float32x4,
        (5126, 1, _) => gpu.VertexFormat.float32,
        (5121, 4, true) => gpu.VertexFormat.unorm8x4,
        (5120, 4, true) => gpu.VertexFormat.snorm8x4,
        (5123, 2, true) => gpu.VertexFormat.unorm16x2,
        (5123, 4, true) => gpu.VertexFormat.unorm16x4,
        (5122, 2, true) => gpu.VertexFormat.snorm16x2,
        (5122, 4, true) => gpu.VertexFormat.snorm16x4,
        _ => throw UnsupportedError(
          'vertex format ${s.componentType} x${s.components}',
        ),
      };
}
