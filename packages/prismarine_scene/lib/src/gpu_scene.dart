import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_assets/prismarine_assets.dart';

import 'gltf_model.dart';
import 'triangle_order.dart';

/// A glTF on the GPU: one device buffer for each buffer view that a
/// primitive reads, its images as textures and its [model]. The images must
/// be KTX2 files, as the prepare step of prismarine_assets writes them.
class GpuScene {
  GpuScene._(this.path, this.model, this.views, this._images);

  /// Reads the glTF at [path] and uploads the buffer views of its
  /// primitives. The textures load on first use or with [loadTextures].
  /// [clusterTriangles] sets the runs of the primitives as for
  /// [GltfModel.read]. Above 0 the triangles of each primitive are sorted
  /// first with [sortTrianglesForRuns].
  factory GpuScene.load(String path, {int clusterTriangles = 4096}) {
    final doc = GltfDocument.open(path);
    if (clusterTriangles > 0) {
      sortTrianglesForRuns(doc, minTriangles: clusterTriangles);
    }
    final model = GltfModel.read(doc, clusterTriangles: clusterTriangles);
    final used = <int>{
      for (final mesh in model.meshes)
        for (final p in mesh)
          if (p != null) ...[
            p.indexView,
            for (final s in p.streams.values) s.view,
          ],
    };
    final defs = doc.list('bufferViews');
    final views = List<gpu.DeviceBuffer?>.filled(defs.length, null);
    for (final v in used) {
      final d = defs[v];
      final start = (d['byteOffset'] as int?) ?? 0;
      final bytes = ByteData.sublistView(
        doc.buffers[d['buffer'] as int],
        start,
        start + (d['byteLength'] as int),
      );
      views[v] = gpu.gpuContext.createDeviceBufferWithCopy(bytes);
    }
    final images = [
      for (final i in doc.list('images'))
        switch (i['uri']) {
          final String uri when uri.endsWith('.ktx2') =>
            '${doc.dir}/${Uri.decodeComponent(uri)}',
          _ => null,
        },
    ];
    return GpuScene._(path, model, views, images);
  }

  final String path;
  final GltfModel model;

  /// The device buffer of each buffer view that a primitive reads, else
  /// null.
  final List<gpu.DeviceBuffer?> views;

  /// The KTX2 file of each image, null for an image of another kind.
  final List<String?> _images;

  final _textures = <int, gpu.Texture>{};
  final _bytes = <int, Uint8List>{};

  /// Returns true when image [image] has a KTX2 file.
  bool hasImage(int image) => image < _images.length && _images[image] != null;

  /// Reads the files of [images] off the UI thread. A later [texture] of
  /// one of them only uploads.
  Future<void> loadTextures(Iterable<int> images) async {
    await Future.wait([
      for (final i in images)
        if (hasImage(i) && !_textures.containsKey(i) && !_bytes.containsKey(i))
          File(_images[i]!).readAsBytes().then((b) => _bytes[i] = b),
    ]);
  }

  /// Image [image] as a texture with every mip level. A colour image is
  /// read through an sRGB format when [srgb] is set.
  gpu.Texture texture(int image, {bool srgb = false}) {
    final key = srgb ? -1 - image : image;
    return _textures[key] ??= _upload(image, srgb);
  }

  gpu.Texture _upload(int image, bool srgb) {
    final file = _images[image];
    if (file == null) {
      throw StateError('$path: image $image is not a KTX2 file');
    }
    final bytes = _bytes.remove(image) ?? File(file).readAsBytesSync();
    final k = readKtx2(bytes);
    final format = switch (k.format) {
      Ktx2Format.rgba8 || Ktx2Format.rgba8Srgb =>
        srgb
            ? gpu.PixelFormat.r8g8b8a8UNormIntSRGB
            : gpu.PixelFormat.r8g8b8a8UNormInt,
      _ => throw StateError('$file: ${k.format.name} is not RGBA8'),
    };
    // The engine makes mip chains down to 2 texels on the smaller side.
    final full = gpu.Texture.fullMipCount(k.width, k.height);
    final mips = k.levels.length < full ? k.levels.length : full;
    final t = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      k.width,
      k.height,
      format: format,
      mipLevelCount: mips,
      enableRenderTargetUsage: false,
    );
    for (var m = 0; m < mips; m++) {
      t.overwrite(ByteData.sublistView(k.levels[m]), mipLevel: m);
    }
    return t;
  }

  /// The textures made so far.
  int get textureCount => _textures.length;
}
