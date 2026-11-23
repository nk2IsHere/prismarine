import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:prismarine_pbr/prismarine_pbr.dart';

import 'fly_camera.dart';
import 'light_show.dart';
import 'sample_renderer.dart';

/// The size of the frames of the smoke test.
const smokeWidth = 1280, smokeHeight = 720;

/// The share of pixels that may differ by more than [smokeLevels] from the
/// reference.
const smokeShare = 0.001, smokeLevels = 2;

/// The frames that the smoke test renders of each view.
const smokeFrames = 24;

/// Renders a fixed frame from each camera of the scene with the first
/// [lightCount] point lights, all by default. Writes each frame as a PNG
/// into [out] and compares it with the reference in `<data>/smoke/<os>`. With [record] the frames become the references.
/// Returns 0 when every frame passed.
Future<int> runSmoke(
  SampleRenderer r,
  String data, {
  bool record = false,
  String? out,
  int? lightCount,
}) async {
  final refs = Directory('$data/smoke/${Platform.operatingSystem}');
  final dir = Directory(out ?? '$data/smoke/last')..createSync(recursive: true);
  if (record) refs.createSync(recursive: true);
  final lights = LightShow.forScene(
    r.builder.boundsMin,
    r.builder.boundsMax,
    r.lamps,
    volume: r.builder.giVolume,
  )..place(7.5);
  for (final (i, l) in lights.lights.indexed) {
    final p = l.position;
    stdout.writeln(
      'SMOKE light $i at ${p.x.toStringAsFixed(3)}, '
      '${p.y.toStringAsFixed(3)}, ${p.z.toStringAsFixed(3)}',
    );
  }
  r.builder.lights
    ..clear()
    ..addAll(lights.lights.take(lightCount ?? lights.lights.length));
  final fly = FlyCamera();
  final view = PbrCamera();
  final cams = r.cameras;
  final hashes = <String, String>{};
  final had = File('${refs.path}/hashes.json');
  final known = had.existsSync()
      ? (jsonDecode(had.readAsStringSync()) as Map).cast<String, String>()
      : const <String, String>{};
  var failed = 0;
  final count = cams.isEmpty ? 3 : cams.length;
  for (var i = 0; i < count; i++) {
    if (cams.isEmpty) {
      fly.frame(
        r.builder.boundsMin,
        r.builder.boundsMax,
        view.yfov,
        turn: 0.6 * (i - 1),
      );
    } else {
      fly.place(cams[i].world);
      view.yfov = cams[i].yfov;
    }
    fly.step(0, _noPad, view);
    // The temporal passes start again at each view and converge over the
    // frames of one jitter cycle and more. The frames after the first run
    // with the shadow pass kept.
    r.builder.resetHistory();
    if (i == 0) await r.warmProbes(view, smokeWidth, smokeHeight);
    for (var f = 0; f < smokeFrames; f++) {
      await r.submit(view, smokeWidth, smokeHeight);
    }
    final rgba = await _read(r);
    final name = 'frame$i';
    final hash = _fnv(rgba);
    hashes[name] = hash;
    File(
      '${dir.path}/$name.png',
    ).writeAsBytesSync(img.encodePng(_image(rgba), level: 1));
    String verdict;
    if (record) {
      File('${dir.path}/$name.png').copySync('${refs.path}/$name.png');
      verdict = 'recorded';
    } else if (known[name] == hash) {
      verdict = 'ok, the same hash';
    } else if (File('${refs.path}/$name.png').existsSync()) {
      final ref = img.decodePng(
        File('${refs.path}/$name.png').readAsBytesSync(),
      )!;
      final (share, worst) = _diff(rgba, ref);
      final ok = share <= smokeShare;
      if (!ok) failed++;
      verdict =
          '${ok ? 'ok' : 'FAILED'}, ${(share * 100).toStringAsFixed(3)} % of '
          'pixels differ by more than $smokeLevels levels, at most $worst';
    } else {
      failed++;
      verdict = 'FAILED, no reference in ${refs.path}. Run with --record';
    }
    stdout.writeln(
      'SMOKE $name ${cams.isEmpty ? 'view $i' : cams[i].name} $hash: $verdict',
    );
  }
  if (record) {
    had.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(hashes));
  }
  stdout.writeln(
    failed == 0
        ? 'SMOKE OK $count frames'
        : 'SMOKE FAILED $failed of $count frames',
  );
  return failed == 0 ? 0 : 1;
}

Future<Uint8List> _read(SampleRenderer r) async {
  final image = r.presented!.asImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

img.Image _image(Uint8List rgba) => img.Image.fromBytes(
  width: smokeWidth,
  height: smokeHeight,
  bytes: rgba.buffer,
  numChannels: 4,
);

/// The share of pixels with a channel more than [smokeLevels] away from
/// [ref], and the largest difference.
(double, int) _diff(Uint8List rgba, img.Image ref) {
  if (ref.width != smokeWidth || ref.height != smokeHeight) return (1, 255);
  final b = ref.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  var over = 0, worst = 0;
  for (var p = 0; p < rgba.length; p += 4) {
    var d = 0;
    for (var c = 0; c < 3; c++) {
      final x = (rgba[p + c] - b[p + c]).abs();
      if (x > d) d = x;
    }
    if (d > smokeLevels) over++;
    if (d > worst) worst = d;
  }
  return (over / (rgba.length / 4), worst);
}

/// The 64-bit FNV-1a hash of [b] in hex.
String _fnv(Uint8List b) {
  var h = 0xcbf29ce484222325;
  for (var i = 0; i < b.length; i++) {
    h = (h ^ b[i]) * 0x100000001b3;
  }
  // Two halves keep the sign bit out of the hex text.
  return (h >>> 32).toRadixString(16).padLeft(8, '0') +
      (h & 0xffffffff).toRadixString(16).padLeft(8, '0');
}

final _noPad = PadState();
