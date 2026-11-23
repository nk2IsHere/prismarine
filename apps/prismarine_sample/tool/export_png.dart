// Writes a copy of a prepared scene with PNG textures, for viewers and path
// tracers that read no KTX2, such as Blender for a reference picture.
//
//   dart tool/export_png.dart <prepared scene dir> <out dir>
//
// The copy has scene.gltf, the buffer of the scene and one PNG per texture
// from its first mip level.
import 'dart:convert';
import 'dart:io';

import 'package:prismarine_assets/prismarine_assets.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart tool/export_png.dart <scene dir> <out dir>');
    exit(64);
  }
  final from = args[0], to = args[1];
  Directory('$to/textures').createSync(recursive: true);
  final json =
      jsonDecode(File('$from/scene.gltf').readAsStringSync())
          as Map<String, Object?>;
  for (final b in (json['buffers'] as List).cast<Map<String, Object?>>()) {
    final uri = Uri.decodeComponent(b['uri']! as String);
    File('$from/$uri').copySync('$to/$uri');
  }
  var count = 0;
  for (final i
      in (json['images'] as List? ?? const []).cast<Map<String, Object?>>()) {
    final uri = i['uri'];
    if (uri is! String || !uri.endsWith('.ktx2')) continue;
    final k = readKtx2(
      File('$from/${Uri.decodeComponent(uri)}').readAsBytesSync(),
    );
    final png = '${uri.substring(0, uri.length - 5)}.png';
    File(
      '$to/${Uri.decodeComponent(png)}',
    ).writeAsBytesSync(encodePng(k.width, k.height, k.levels.first));
    i
      ..['uri'] = png
      ..['mimeType'] = 'image/png';
    count++;
  }
  File('$to/scene.gltf').writeAsStringSync(jsonEncode(json));
  stdout.writeln('export_png: $count textures as PNG in $to');
}
