// Takes heap snapshots of the test process and checks the dominator tree and
// heap_diff on them.
import 'dart:developer' show NativeRuntime;
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_profiler/heap_dominators.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

final class Holder {
  Holder(this.bytes);
  final Uint8List bytes;
}

Holder? held;

HeapSnapshotGraph _read(String path) => HeapSnapshotGraph.fromChunks(
  [ByteData.sublistView(File(path).readAsBytesSync())],
  calculateReferrers: false,
  decodeObjectData: true,
  decodeIdentityHashCodes: false,
);

String _snapshot(Directory dir, String name) {
  final path = '${dir.path}/$name.dartheap';
  NativeRuntime.writeHeapSnapshotToFile(path);
  return path;
}

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('profiler_test'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('the holder of a list retains the bytes of the list', () {
    held = Holder(Uint8List(8 << 20));
    final g = _read(_snapshot(dir, 'one'));
    final d = HeapDominators(g);
    final holders = [
      for (var i = 1; i < g.objects.length; i++)
        if (g.classes[g.objects[i].classId].name == 'Holder') i,
    ];
    expect(holders, hasLength(1));
    final h = holders.single;
    expect(d.retained[h], greaterThanOrEqualTo(8 << 20));
    expect(d.retained[1], greaterThan(d.retained[h]));
    final list = g.objects[h].references.firstWhere(
      (r) => g.classes[g.objects[r].classId].name == '_Uint8List',
    );
    expect(d.idom[list], h);
    expect(d.fieldName(h, list), 'bytes');
  });

  test('heap_diff prints the growth under the field that holds it', () {
    held = null;
    final a = _snapshot(dir, 'a');
    held = Holder(Uint8List(16 << 20));
    final b = _snapshot(dir, 'b');
    final r = Process.runSync(Platform.resolvedExecutable, [
      'bin/heap_diff.dart',
      a,
      b,
      '--min=8',
      '--top=5',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final lines = '${r.stdout}'.split('\n');
    final row = lines.firstWhere(
      (l) => l.endsWith('Holder > .bytes:_Uint8List'),
      orElse: () => fail('no row of Holder.bytes in\n${r.stdout}'),
    );
    final mb = row.trim().split(RegExp(r'\s+'));
    expect(double.parse(mb[0]), 0);
    expect(double.parse(mb[1]), closeTo(16.8, 0.1));
    expect(double.parse(mb[2]), closeTo(16.8, 0.1));
  });
}
