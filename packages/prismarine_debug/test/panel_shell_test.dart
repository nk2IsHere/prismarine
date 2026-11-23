import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

class _Samples extends FrameSamples {
  _Samples() : super([FrameGroupStyle('work', const Color(0xFF27AE60))]);

  @override
  FrameSample newSample() => _Sample();
}

class _Sample extends FrameSample {
  _Sample() : super(1);

  @override
  void sort(String section, double v) => ms[0] += v;
}

void main() {
  testWidgets('the header, the frame graph and the sections show; a '
      'collapsed section stays collapsed across rebuilds', (tester) async {
    tester.view.physicalSize = const Size(380, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = _Samples();
    for (var i = 0; i < 100; i++) {
      d.endFrame(
        d.beginFrame()
          ..dt = 1 / 60
          ..add('work', 4),
        raster: 2,
      );
    }
    var label = 'first';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return DebugPanelShell(
              samples: d,
              header: (context, p) => [
                Text('${d.fps.toStringAsFixed(0)} fps', style: p.small),
              ],
              sections: (context, p) => [
                PanelSection(
                  'Tools',
                  open: p.open,
                  children: [Text('tool $label', style: p.small)],
                ),
              ],
            );
          },
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('60 fps'), findsOneWidget);
    expect(find.text('Frame graph'), findsOneWidget);
    expect(find.byType(FrameGraph), findsOneWidget);
    expect(find.text('work 4.0'), findsOneWidget);
    expect(find.text('raster 2.0 ms'), findsOneWidget);
    expect(find.text('tool first'), findsOneWidget);
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('tool first'), findsNothing);
    rebuild(() => label = 'second');
    await tester.pumpAndSettle();
    expect(find.text('tool second'), findsNothing);
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('tool second'), findsOneWidget);
  });

  testWidgets('the panel\'s build time goes to the open frame', (tester) async {
    final d = _Samples();
    final f = d.beginFrame();
    d.endFrame(f, keepOpen: true);
    await tester.pumpWidget(
      MaterialApp(
        home: DebugPanelShell(
          samples: d,
          header: (context, p) => const [],
          sections: (context, p) => const [],
        ),
      ),
    );
    expect([
      for (var i = 0; i < f.sectionCount; i++) f.sectionNames[i],
    ], contains('panel.build'));
  });
}
