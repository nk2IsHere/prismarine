import 'dart:convert';
import 'dart:io';

/// The stamp of a cook output, a JSON file with the key of its inputs.
class Stamp {
  Stamp(this.path);
  final String path;

  /// The key in the file, or null when the file is missing or unreadable.
  String? get key {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      return j is Map ? j['key'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// The other fields of the file, empty when it is missing.
  Map<String, Object?> get fields {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      return j is Map ? j.cast<String, Object?>() : const {};
    } on Object {
      return const {};
    }
  }

  /// Writes [key] with [fields]. An unchanged file keeps its bytes and time.
  /// A new file gets a time in the year 2000. A build hook lists the stamp as
  /// a dependency, and a newer time would run the hook again on the next
  /// build.
  void write(String key, [Map<String, Object?> fields = const {}]) {
    final text = const JsonEncoder.withIndent(
      ' ',
    ).convert({'key': key, ...fields});
    final f = File(path);
    if (f.existsSync() && f.readAsStringSync() == text) return;
    f
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    try {
      f.setLastModifiedSync(DateTime.utc(2000));
    } on FileSystemException {
      // A file system without settable times runs the hook once more.
    }
  }

  void delete() {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
}
