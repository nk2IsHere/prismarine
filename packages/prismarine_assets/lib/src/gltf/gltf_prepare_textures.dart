import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../image/ktx2.dart';
import '../image/mips.dart';
import 'gltf_document.dart';

/// The images and textures of a prepared glTF and the number of KTX2 files.
class PreparedTextures {
  PreparedTextures(this.images, this.textures, this.count);
  final List<Map<String, Object?>> images, textures;
  final int count;
}

/// Converts each image of [doc] that a texture uses into
/// `<outDir>/textures/<image>.ktx2`, [jobs] at a time.
Future<PreparedTextures> prepareTextures(
  GltfDocument doc,
  String outDir, {
  required int textureSize,
  required int jobs,
  void Function(String line)? log,
}) async {
  final uses = imageUses(doc);
  final images = doc.list('images');
  final out = <Map<String, Object?>>[];
  final work = <(int, TextureUse)>[];
  for (var i = 0; i < images.length; i++) {
    out.add({'uri': 'textures/$i.ktx2', 'mimeType': 'image/ktx2'});
    if (uses[i] case final use?) work.add((i, use));
  }
  var next = 0, done = 0;
  Future<void> worker() async {
    while (next < work.length) {
      final (i, use) = work[next++];
      final target = '$outDir/textures/$i.ktx2';
      final image = images[i];
      final uri = image['uri'] as String?;
      final path = uri == null || uri.startsWith('data:')
          ? null
          : '${doc.dir}/${Uri.decodeComponent(uri)}';
      final have = File(target);
      if (path != null &&
          have.existsSync() &&
          have.lastModifiedSync().isAfter(File(path).lastModifiedSync())) {
        done++;
        continue;
      }
      final bytes = path == null ? _imageBytes(doc, image) : null;
      final sw = Stopwatch()..start();
      final size = await _inIsolate(path, bytes, use, textureSize, target);
      done++;
      log?.call(
        'texture $done/${work.length}: ${uri ?? 'image $i'} ${use.name} '
        '$size in ${sw.elapsedMilliseconds} ms',
      );
    }
  }

  await Future.wait([for (var j = 0; j < jobs; j++) worker()]);
  final textures = [
    for (final t in doc.list('textures'))
      {'sampler': ?t['sampler'], 'source': ?t['source'], 'name': ?t['name']},
  ];
  return PreparedTextures(out, textures, work.length);
}

/// The use of each image that a material samples, by image index. An image
/// that a base colour or emissive texture uses is colour, one that a normal
/// texture uses is a normal map, any other is data.
Map<int, TextureUse> imageUses(GltfDocument doc) {
  final textures = doc.list('textures');
  final uses = <int, TextureUse>{};
  void use(Object? info, TextureUse u) {
    if (info is! Map) return;
    final source = textures[info['index'] as int]['source'] as int?;
    if (source == null) return;
    final had = uses[source];
    // Colour wins over data, the transfer function matters most there.
    if (had == null || had == TextureUse.data) uses[source] = u;
  }

  for (final m in doc.list('materials')) {
    final pbr = m['pbrMetallicRoughness'] as Map?;
    use(pbr?['baseColorTexture'], TextureUse.color);
    use(m['emissiveTexture'], TextureUse.color);
    use(m['normalTexture'], TextureUse.normal);
    use(pbr?['metallicRoughnessTexture'], TextureUse.data);
    use(m['occlusionTexture'], TextureUse.data);
  }
  return uses;
}

Uint8List _imageBytes(GltfDocument doc, Map<String, Object?> image) {
  final uri = image['uri'] as String?;
  if (uri != null) return GltfDocument.readUri(uri, doc.dir);
  final v = doc.list('bufferViews')[image['bufferView'] as int];
  final start = (v['byteOffset'] as int?) ?? 0;
  return Uint8List.sublistView(
    doc.buffers[v['buffer'] as int],
    start,
    start + (v['byteLength'] as int),
  );
}

// A function of its own, so that the closure sent to the isolate holds
// only these arguments and not the document.
Future<String> _inIsolate(
  String? path,
  Uint8List? bytes,
  TextureUse use,
  int maxSize,
  String target,
) => Isolate.run(() => _convert(path, bytes, use, maxSize, target));

/// Decodes the image at [path] or in [bytes], makes its mips and writes
/// the KTX2 file. Returns the size of its first level.
String _convert(
  String? path,
  Uint8List? bytes,
  TextureUse use,
  int maxSize,
  String target,
) {
  final data = bytes ?? File(path!).readAsBytesSync();
  final decoded = img.decodeImage(data);
  if (decoded == null) {
    throw FormatException(
      '${path ?? 'an embedded image'} is not a PNG or JPEG image that the '
      'prepare step decodes',
    );
  }
  final rgba = decoded
      .convert(format: img.Format.uint8, numChannels: 4, alpha: 255)
      .getBytes(order: img.ChannelOrder.rgba);
  final (w, h, levels) = mipChainRgba8(
    rgba,
    decoded.width,
    decoded.height,
    use,
    maxSize: maxSize,
  );
  final ktx = encodeKtx2(
    format: use == TextureUse.color ? Ktx2Format.rgba8Srgb : Ktx2Format.rgba8,
    width: w,
    height: h,
    levels: levels,
    writer: 'prismarine_assets prepareGltf',
  );
  final tmp = File('$target.part')..writeAsBytesSync(ktx);
  tmp.renameSync(target);
  return '${w}x$h';
}
