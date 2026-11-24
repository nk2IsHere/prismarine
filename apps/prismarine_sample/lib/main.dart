// The sample of prismarine: Intel's Sponza drawn by prismarine_pbr through
// prismarine_render, with a fly camera, moving point lights, gamepads and
// the debug panel. `--smoke` renders fixed frames and checks them, and
// `--perf=<seconds>` flies a fixed path and logs the frame times.
// `--shot=<png>` lays the view out at 1600 by 900 points with `--panel`
// open or not and writes it after `--shot-after=<seconds>`, 8 by default.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

import 'src/perf.dart';
import 'src/sample_data.dart';
import 'src/sample_options.dart';
import 'src/sample_renderer.dart';
import 'src/sample_view.dart';
import 'src/smoke.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  String? opt(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final data = sampleDataDir(opt('data'));
  final perf = double.tryParse(opt('perf') ?? '');
  runApp(
    SampleApp(
      data: data,
      smoke: args.contains('--smoke'),
      record: args.contains('--record'),
      perf: perf,
      out: opt('out'),
      shot: opt('shot'),
      shotAfter: double.tryParse(opt('shot-after') ?? '') ?? 8,
      panel: args.contains('--panel'),
      shadowView: args.contains('--shadow-view'),
      noShadows: args.contains('--no-shadows'),
      timed: args.contains('--timed'),
      options: {
        for (final a in args)
          if (a.startsWith('--') && a.contains('='))
            a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
      },
      sun: opt(
        'sun',
      )?.split(',').map((v) => double.parse(v) * math.pi / 180).toList(),
    ),
  );
}

class SampleApp extends StatefulWidget {
  const SampleApp({
    super.key,
    required this.data,
    this.smoke = false,
    this.record = false,
    this.perf,
    this.out,
    this.shot,
    this.shotAfter = 8,
    this.panel = false,
    this.shadowView = false,
    this.noShadows = false,
    this.timed = false,
    this.options = const {},
    this.sun,
  });

  final String data;
  final bool smoke, record;
  final double? perf;

  /// The directory of the smoke frames or the perf log.
  final String? out;

  /// The PNG of a picture of the view, the seconds before it is taken and
  /// whether the panel shows.
  final String? shot;
  final double shotAfter;
  final bool panel;

  /// Shows the shadow map in a corner from the start.
  final bool shadowView;

  /// Starts with the sun's shadows off.
  final bool noShadows;

  /// Splits the frames of the performance run into timed parts.
  final bool timed;

  /// The options of the command line by name, for [applyRenderOptions].
  final Map<String, String> options;

  /// The elevation and azimuth of the sun in radians, or null for the
  /// directional light of the scene.
  final List<double>? sun;

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  SampleRenderer? _renderer;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sw = Stopwatch()..start();
      final r = await SampleRenderer.load(widget.data);
      r.builder.settings
        ..showShadowMap = widget.shadowView
        ..shadows = !widget.noShadows;
      applyRenderOptions(r.builder.settings, (n) => widget.options[n]);
      r.timed = widget.timed;
      if (widget.sun case [final elevation, final azimuth]) {
        r.builder.settings.sunDirection.setValues(
          math.cos(elevation) * math.cos(azimuth),
          math.sin(elevation),
          math.cos(elevation) * math.sin(azimuth),
        );
      }
      stdout.writeln(
        'sample: loaded ${r.scenes.length} scenes, '
        '${r.builder.images.length} textures in ${sw.elapsedMilliseconds} ms',
      );
      if (widget.smoke) {
        exit(
          await runSmoke(
            r,
            widget.data,
            record: widget.record,
            out: widget.out,
            lightCount: int.tryParse(widget.options['lights'] ?? ''),
          ),
        );
      }
      setState(() => _renderer = r);
      if (widget.shot case final path?) {
        Timer(
          Duration(milliseconds: (widget.shotAfter * 1000).round()),
          () => _takeShot(path),
        );
      }
    } on EngineMismatch catch (e) {
      stderr.writeln('sample: $e');
      if (widget.smoke || widget.perf != null) exit(1);
      setState(() => _error = e);
    } on SampleDataMissing catch (e) {
      stderr.writeln('sample: $e');
      if (widget.smoke || widget.perf != null) exit(1);
      setState(() => _error = e);
    } on Object catch (e, st) {
      stderr.writeln('sample: $e\n$st');
      if (widget.smoke || widget.perf != null) exit(1);
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _renderer;
    final Widget body;
    if (r != null && widget.perf != null) {
      body = PerfRun(r, seconds: widget.perf!, out: widget.out);
    } else if (r != null) {
      body = SampleView(r, panel: widget.panel);
    } else {
      body = Center(
        child: Text(
          _error?.toString() ?? 'Loading the scene',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    final Widget home = widget.shot == null
        ? body
        : OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 1600,
            maxWidth: 1600,
            minHeight: 900,
            maxHeight: 900,
            child: RepaintBoundary(key: _shotKey, child: body),
          );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      // The Material gives every text of the app its text style.
      home: Material(color: Colors.black, child: home),
    );
  }

  final _shotKey = GlobalKey();

  Future<void> _takeShot(String path) async {
    final box =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final image = await box.toImage(pixelRatio: dpr);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
    stdout.writeln('sample: wrote $path, ${image.width}x${image.height}');
    exit(0);
  }
}
