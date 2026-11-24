import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

void main() {
  test('the release constant is the one of RELEASE', () {
    final release = File(
      '../../third_party/flutter_engine/RELEASE',
    ).readAsStringSync().trim();
    expect(prismarineEngineRelease, release);
  });

  test('missing features are listed in words', () {
    expect(EngineFeatures.describe(EngineFeatures.compute), 'compute');
    expect(
      EngineFeatures.describe(
        EngineFeatures.compute |
            EngineFeatures.bindings |
            EngineFeatures.oldSpace,
      ),
      'compute, the added bindings and the heap figures',
    );
  });

  test('the engine of the tester fails the check with the fix', () {
    final p = engineProblem(EngineFeatures.compute);
    expect(p, contains('prismarine build'));
  });
}
