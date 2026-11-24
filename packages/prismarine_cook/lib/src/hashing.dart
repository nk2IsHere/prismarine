import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Returns the files under each of [paths] in a fixed order. A path of a file
/// gives that file. A missing path gives no files.
List<File> filesUnder(Iterable<String> paths) {
  final out = <File>[];
  for (final p in paths) {
    if (FileSystemEntity.isDirectorySync(p)) {
      final files =
          Directory(p).listSync(recursive: true).whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      out.addAll(files);
    } else if (File(p).existsSync()) {
      out.add(File(p));
    }
  }
  return out;
}

/// Returns a SHA-256 in hex over [parts] and over the path relative to its
/// root and the bytes of every file under each root of [trees].
String hashInputs(List<String> parts, {List<String> trees = const []}) {
  final sink = _Collect();
  final input = sha256.startChunkedConversion(sink);
  void text(String s) {
    final b = utf8.encode(s);
    input.add(utf8.encode('${b.length}:'));
    input.add(b);
  }

  for (final p in parts) {
    text(p);
  }
  for (final root in trees) {
    text('tree $root');
    final isDir = FileSystemEntity.isDirectorySync(root);
    for (final f in filesUnder([root])) {
      final rel = isDir
          ? f.path.substring(root.length).replaceAll(r'\', '/')
          : '';
      text('file $rel ${f.lengthSync()}');
      input.add(f.readAsBytesSync());
    }
  }
  input.close();
  return sink.value.toString();
}

/// Returns the SHA-256 in hex of the bytes of [path]. The result is kept until
/// the process ends, per path, size and time of the file.
String hashFile(String path) {
  final f = File(path);
  final s = f.statSync();
  final key = '$path ${s.size} ${s.modified.microsecondsSinceEpoch}';
  return _fileHashes[key] ??= sha256.convert(f.readAsBytesSync()).toString();
}

final _fileHashes = <String, String>{};

class _Collect implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
