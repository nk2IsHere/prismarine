import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

void main() {
  final plan = FramePlan(const {
    'color': TargetSpec(4, 2, 'R8G8B8A8_UNORM'),
  }, const []);
  final blobs = <String, Uint8List>{};
  String put(Uint8List b) {
    final name = 'b${blobs.length}';
    blobs[name] = b;
    return name;
  }

  Uint8List get(String name) => blobs[name]!;

  test('a plan reads back with its format tag', () {
    final j = planToJson(plan, put);
    expect(j['format'], framePlanFormat);
    expect(planFromJson(j, get).targets['color']!.width, 4);
  });

  test('a caller gives its own format tag', () {
    final j = planToJson(plan, put, format: 'other/2');
    expect(j['format'], 'other/2');
    expect(planFromJson(j, get, format: 'other/2').targets, hasLength(1));
    expect(() => planFromJson(j, get), throwsFormatException);
  });
}
