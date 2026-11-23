import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_pbr/prismarine_pbr.dart';
import 'package:prismarine_render/prismarine_render.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

/// The scene of the sample on the GPU with its renderer: the prepared
/// packages of the data directory, the shaders, the builder and the frame
/// runner.
class SampleRenderer {
  SampleRenderer._(this.scenes, this.builder, this.runner, this.credits);

  /// Loads every prepared package in `<dataDir>/prepared` and the shader
  /// bundle of the app's assets, then reads every texture.
  static Future<SampleRenderer> load(String dataDir) async {
    final root = Directory('$dataDir/prepared');
    if (!root.existsSync()) {
      throw StateError(
        'No prepared scene in $dataDir. Run `dart tool/fetch.dart` in '
        'apps/prismarine_sample first, or set PRISMARINE_SAMPLE_DATA.',
      );
    }
    // The base scene first, then the add-ons in name order.
    final dirs =
        root
            .listSync()
            .whereType<Directory>()
            .where((d) => File('${d.path}/scene.gltf').existsSync())
            .toList()
          ..sort((a, b) {
            final an = _name(a), bn = _name(b);
            if (an == 'main') return -1;
            if (bn == 'main') return 1;
            return an.compareTo(bn);
          });
    final scenes = <String, GpuScene>{
      for (final d in dirs) _name(d): GpuScene.load('${d.path}/scene.gltf'),
    };
    final backend = Platform.isMacOS ? 'metal' : 'vulkan';
    final bundle = await rootBundle.load(
      'shaders_generated/bundle/$backend/Pbr.0.shaderbundle.gz',
    );
    final shaders = await PbrShaderBundle.load(
      bundle.buffer.asUint8List(bundle.offsetInBytes, bundle.lengthInBytes),
      await rootBundle.loadString('shaders_generated/records.json'),
    );
    final assets = PbrAssets(shaders, scenes);
    final builder = PbrBuilder([
      for (final MapEntry(:key, :value) in scenes.entries)
        PbrScene(key, value.model),
    ]);
    await assets.loadTextures({
      for (final (s, i) in builder.images) s.textureStem(i),
    });
    // The sun shines from the first directional light of the scenes that
    // has an intensity. Sponza's sun has none and leaves the ground floor in
    // shade, so the default sun of the settings shines there.
    for (final s in scenes.values) {
      for (final l in s.model.lights) {
        if (l.type != 'directional' || l.intensity <= 0) continue;
        builder.settings.sunDirection
          ..setFrom(l.direction)
          ..negate();
        break;
      }
    }
    final runner = FrameRunner(assets, pbrRunnerShaders)
      ..warn = (m) => stderr.writeln('sample: $m');
    final credits = [
      for (final d in dirs)
        if (File('${d.path}/credits_license.txt') case final f
            when f.existsSync())
          _creditLines(f.readAsStringSync()),
    ];
    return SampleRenderer._(scenes, builder, runner, credits);
  }

  static String _name(Directory d) =>
      d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  /// The lines of a credits file before its licence text.
  static String _creditLines(String text) {
    final end = text.indexOf('=====');
    return (end < 0 ? text : text.substring(0, end)).trim();
  }

  final Map<String, GpuScene> scenes;
  final PbrBuilder builder;
  final FrameRunner runner;

  /// The credits of each package as their files give them.
  final List<String> credits;

  /// The cameras of every scene.
  List<ModelCamera> get cameras => [
    for (final s in scenes.values) ...s.model.cameras,
  ];

  /// The punctual lights of every scene.
  Iterable<ModelLight> get lamps sync* {
    for (final s in scenes.values) {
      yield* s.model.lights;
    }
  }

  int _inFlight = 0;

  /// The frames that the GPU has not finished.
  int get inFlight => _inFlight;

  /// The last finished frame, or null before the first.
  gpu.Texture? get presented => runner.presented;

  /// Counts finished frames.
  int finished = 0;

  /// Receives each finished frame.
  void Function()? onFrame;

  /// The time of the last [submit] to build its plan, in ms.
  double lastBuildMs = 0;

  final _build = Stopwatch();

  /// Splits the frame into the timed parts of the builder.
  bool timed = false;

  /// The section of the frame graph of each timed part, as
  /// `PbrBuilder.partLabels` gives them.
  List<String> gpuSections = const [];
  List<String> _labels = const [];

  /// Builds the plan of camera [camera] at [width] by [height], [dt]
  /// seconds after the last frame, and runs it. Returns the future of the
  /// run, which completes when the GPU is done.
  Future<bool> submit(
    PbrCamera camera,
    int width,
    int height, {
    double dt = 1 / 60,
  }) {
    _build
      ..reset()
      ..start();
    final plan = builder.frame(camera, width, height, dt: dt);
    runner.timedParts = timed ? builder.timedPasses : const [];
    if (!identical(_labels, builder.partLabels)) _sections();
    lastBuildMs = _build.elapsedMicroseconds / 1000;
    _inFlight++;
    // alloc: the runner's run is asynchronous and returns a future.
    return runner.run(plan, present: PbrTargets.backbuffer).whenComplete(_done);
  }

  // alloc-cold: the labels change with a new plan.
  void _sections() {
    _labels = builder.partLabels;
    gpuSections = [for (final l in _labels) 'gpu $l'];
  }

  void _done() {
    _inFlight--;
    finished++;
    onFrame?.call();
  }
}
