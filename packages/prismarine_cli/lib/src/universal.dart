import 'dart:convert';
import 'dart:io';

import 'tools.dart';
import 'ui.dart';

/// Merges the macOS app [arm] built for arm64 and the app [x64] built for
/// x86_64 into the universal app [out]. lipo joins each pair of Mach-O files.
/// The other files must be equal. The exceptions are the native assets
/// manifest, which keeps the entries of both CPUs, the signatures and the
/// engine revision string. The last two come from [arm]. The result has an
/// ad hoc signature. Returns the number of merged files.
Future<int> mergeUniversalApp(
  String arm,
  String x64,
  String out,
  Tools tools,
) async {
  final dir = Directory(out);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await tools.must(
    ['ditto', arm, out],
    log: 'universal',
    cause: 'The copy of $arm failed.',
  );
  var merged = 0;
  for (final e in Directory(
    arm,
  ).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(arm.length);
    final other = File('$x64$rel');
    if (_isMachO(e)) {
      if (!other.existsSync()) {
        throw Failure(
          'The x86_64 build lacks $rel.',
          fix: 'prismarine build macos --universal',
        );
      }
      final archs = tools.read(['lipo', '-archs', e.path]) ?? '';
      if (archs.split(' ').contains('x86_64')) continue;
      await tools.must(
        ['lipo', '-create', e.path, other.path, '-output', '$out$rel'],
        log: 'universal',
        cause: 'lipo failed for $rel.',
      );
      merged++;
    } else if (!other.existsSync() || !_same(e, other)) {
      if (rel.contains('/_CodeSignature/') ||
          rel.endsWith('/CodeResources') ||
          rel.endsWith(
            '/FlutterMacOS.framework/Versions/A/Resources/Info.plist',
          )) {
        continue;
      }
      if (rel.endsWith('/NativeAssetsManifest.json') && other.existsSync()) {
        final a = jsonDecode(e.readAsStringSync()) as Map<String, Object?>;
        final b = jsonDecode(other.readAsStringSync()) as Map<String, Object?>;
        (a['native-assets'] as Map).addAll(b['native-assets'] as Map);
        File('$out$rel').writeAsStringSync(jsonEncode(a));
        continue;
      }
      throw Failure(
        'The file $rel differs between the arm64 and x86_64 builds.',
      );
    }
  }
  await tools.must(
    ['codesign', '--force', '--deep', '-s', '-', out],
    log: 'universal',
    cause: 'codesign failed for $out.',
  );
  return merged;
}

bool _isMachO(File f) {
  final r = f.openSync();
  try {
    final b = r.readSync(4);
    if (b.length < 4) return false;
    final m = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return const {
      0xfeedface,
      0xfeedfacf,
      0xcefaedfe,
      0xcffaedfe,
      0xcafebabe,
      0xbebafeca,
    }.contains(m);
  } finally {
    r.closeSync();
  }
}

bool _same(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) return false;
  final x = a.readAsBytesSync(), y = b.readAsBytesSync();
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
