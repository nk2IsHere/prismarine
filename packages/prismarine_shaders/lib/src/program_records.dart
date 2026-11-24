import 'dart:io';

import 'shader_interface.dart';

/// Returns the interface of every program of the program tree in
/// [programs], by entry id such as `Pbr/lit.frag`, in the JSON form of
/// [shaderInterface]. A program is read with its includes in place and the
/// lines that its `#ifdef` and `#ifndef` blocks leave out removed. The files
/// of a `bodies` folder are includes and have no record.
Map<String, Object?> programRecords(String programs) {
  final source = Directory(programs);
  final records = <String, Object?>{};
  final files = source.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final id = f.path.substring(source.path.length + 1).replaceAll(r'\', '/');
    if (id.split('/').contains('bodies')) continue;
    final stage = switch (id.split('.').last) {
      'vert' => 'vertex',
      'comp' => 'compute',
      _ => 'pixel',
    };
    records[id] = shaderInterface(_expand(f, source), stage);
  }
  return records;
}

String _expand(File f, Directory root) {
  final defined = <String>{};
  final active = <bool>[];
  final out = StringBuffer();
  for (final line in _included(f, root).split('\n')) {
    final t = line.trim();
    final on = active.every((a) => a);
    if (t.startsWith('#ifdef ') || t.startsWith('#ifndef ')) {
      final name = t.split(RegExp(r'\s+'))[1];
      active.add(defined.contains(name) == t.startsWith('#ifdef '));
    } else if (t.startsWith('#else')) {
      active.add(!active.removeLast());
    } else if (t.startsWith('#endif')) {
      active.removeLast();
    } else if (on) {
      if (t.startsWith('#define ')) defined.add(t.split(RegExp(r'\s+'))[1]);
      out.writeln(line);
    }
  }
  return out.toString();
}

String _included(File f, Directory root) =>
    f.readAsStringSync().replaceAllMapped(
      RegExp(r'#include "([^"]+)"'),
      (m) => _included(File('${root.path}/${m[1]}'), root),
    );
