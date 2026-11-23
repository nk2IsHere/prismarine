// The sample of prismarine: Intel's Sponza drawn by prismarine_pbr through
// prismarine_render, with a fly camera, moving point lights, gamepads and
// the debug panel. `--smoke` renders fixed frames and checks them, and
// `--perf=<seconds>` flies a fixed path and logs the frame times.
// `--shot=<png>` lays the view out at 1600 by 900 points with `--panel`
// open or not and writes it after `--shot-after=<seconds>`, 8 by default.
// `--gi=off`, `--gi-off=<effects>`, `--quality=<preset>` and
// `--debug-view=<view>` set the indirect light.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:prismarine_pbr/prismarine_pbr.dart';

import 'src/perf.dart';
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

  final data = opt('data') ?? defaultDataDir();
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
      sun: opt(
        'sun',
      )?.split(',').map((v) => double.parse(v) * math.pi / 180).toList(),
      giOff: opt('gi') == 'off'
          ? const {'sky', 'probes', 'ao', 'ssr'}
          : (opt('gi-off')?.split(',').toSet() ?? const {}),
      quality: opt('quality'),
      debugView: opt('debug-view'),
    ),
  );
}

/// The data directory: `PRISMARINE_SAMPLE_DATA`, else `data/sample` of the
/// repository when the app runs from its tree.
String defaultDataDir() {
  final env = Platform.environment['PRISMARINE_SAMPLE_DATA'];
  if (env != null && env.isNotEmpty) return env;
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/apps/prismarine_sample/pubspec.yaml').existsSync()) {
      return '${dir.path}/data/sample';
    }
    dir = dir.parent;
  }
  return '${Directory.current.path}/data/sample';
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
    this.sun,
    this.giOff = const {},
    this.quality,
    this.debugView,
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

  /// The elevation and azimuth of the sun in radians, or null for the
  /// directional light of the scene.
  final List<double>? sun;

  /// The effects of the indirect light to switch off: `sky`, `probes`, `ao`
  /// and `ssr`.
  final Set<String> giOff;

  /// The name of the quality preset and of the debug view, or null for the
  /// defaults.
  final String? quality, debugView;

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
      final off = widget.giOff;
      final r = await SampleRenderer.load(
        widget.data,
        gi: !off.contains('probes'),
      );
      r.builder.settings
        ..showShadowMap = widget.shadowView
        ..shadows = !widget.noShadows;
      final gi = r.builder.settings.gi;
      if (widget.quality case final q?) gi.quality = GiQuality.values.byName(q);
      if (widget.debugView case final v?) {
        gi.debugView = GiDebugView.values.byName(v);
      }
      gi
        ..sky = !off.contains('sky')
        ..probes = !off.contains('probes')
        ..ambientOcclusion = !off.contains('ao')
        ..reflections = !off.contains('ssr');
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
