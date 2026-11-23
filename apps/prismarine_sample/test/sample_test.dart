import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:prismarine_pbr/builder.dart';
import 'package:prismarine_sample/src/fly_camera.dart';
import 'package:prismarine_sample/src/light_show.dart';
import 'package:prismarine_sample/src/sample_data.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

import '../tool/src/remote_zip.dart';

void main() {
  test('Crc32 gives the check value of zip files', () {
    final c = Crc32()..add(ascii.encode('123456789'));
    expect(c.value, 0xcbf43926);
  });

  test('the data directory is the flag, else the folder of the user', () {
    expect(sampleDataDir('/somewhere'), '/somewhere');
    final set = Platform.environment['PRISMARINE_SAMPLE_DATA'];
    final dir = sampleDataDir();
    if (set != null && set.isNotEmpty) {
      expect(dir, set);
    } else if (Platform.isWindows) {
      expect(dir, endsWith(r'\prismarine\sample'));
    } else {
      expect(dir, endsWith('/.prismarine/sample'));
    }
    expect('${SampleDataMissing('/x')}', contains('dart tool/fetch.dart'));
  });

  test('a placed camera looks along the negative z axis of its node', () {
    final world = Matrix4.compose(
      Vector3(1, 2, 3),
      Quaternion.axisAngle(Vector3(0, 1, 0), 0.5),
      Vector3.all(1),
    );
    final fly = FlyCamera()..place(world);
    final view = PbrCamera();
    fly.step(0, PadState(), view);
    final back = Matrix4.inverted(view.view);
    for (var i = 0; i < 16; i++) {
      expect(back.storage[i], closeTo(world.storage[i], 1e-9));
    }
  });

  test('the camera moves forward with W', () {
    final fly = FlyCamera()..forward = true;
    final view = PbrCamera();
    fly.step(1, PadState(), view);
    expect(view.position.z, closeTo(-fly.speed, 1e-9));
  });

  test('the lights follow the box of the point lamps', () {
    ModelLight lamp(double x, double y, double z) => ModelLight(
      'point',
      Vector3.all(1),
      1,
      null,
      Vector3(x, y, z),
      Vector3(0, 0, -1),
    );
    final show = LightShow.forScene(Vector3.all(-100), Vector3.all(100), [
      lamp(-10, 4, -5),
      lamp(10, 8, 5),
    ])..place(0);
    expect(show.center, Vector3(0, 6, 0));
    for (final l in show.lights) {
      expect(l.position.x.abs(), lessThanOrEqualTo(9.01));
      expect(l.position.z.abs(), lessThanOrEqualTo(4.01));
    }
  });
}
