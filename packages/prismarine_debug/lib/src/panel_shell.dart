// The shell of the debug panel. It shows the lines of the application at
// the top, the frame graph and then the sections of the application on a
// dark card that scrolls as a whole.
import 'package:flutter/material.dart';

import 'frame_graph.dart';
import 'frame_samples.dart';
import 'profiler.dart' show UiWork;

/// The text theme, the small text style and the open state of the sections
/// by id, which the parts of a debug panel share.
class PanelContext {
  const PanelContext(this.text, this.small, this.open);
  final TextTheme text;
  final TextStyle small;
  final Map<String, bool> open;
}

/// Builds the widgets of a part of the panel in order.
typedef PanelPart = List<Widget> Function(BuildContext context, PanelContext p);

/// Shows [header], the frame graph of [samples] and then [sections] as the
/// debug panel. The build time of the panel goes to the profiler and to the
/// open frame as `panel.build`.
class DebugPanelShell extends StatefulWidget {
  const DebugPanelShell({
    super.key,
    required this.samples,
    required this.header,
    required this.sections,
  });

  final FrameSamples samples;
  final PanelPart header, sections;

  @override
  State<DebugPanelShell> createState() => _DebugPanelShellState();
}

class _DebugPanelShellState extends State<DebugPanelShell> {
  /// The open state of the sections by id. A PageStorage entry would share
  /// its id with the scroll offsets of the text fields inside the section.
  final _open = <String, bool>{};

  @override
  Widget build(BuildContext context) {
    // Times the build of the panel as `panel.build`. Its layout and paint
    // are not timed.
    final sw = Stopwatch()..start();
    final w = _build(context);
    final ms = sw.elapsedMicroseconds / 1000;
    UiWork.add(ms);
    widget.samples.profiler?.add('panel.build', ms);
    widget.samples.openFrame?.add('panel.build', ms);
    return w;
  }

  Widget _build(BuildContext context) {
    final d = widget.samples;
    final text = Theme.of(context).textTheme;
    final small = text.bodySmall!.copyWith(fontSize: 11);
    final p = PanelContext(text, small, _open);
    return Material(
      color: const Color(0xF0181A1F),
      child: Padding(
        padding: const EdgeInsets.all(10),
        // The card scrolls as a whole to fit any window height.
        child: ListView(
          children: [
            ...widget.header(context, p),
            PanelSection(
              'Frame graph',
              open: _open,
              children: [
                FrameGraph(d, style: small),
                const SizedBox(height: 4),
                // Means over the last 60 frames, rebuilt with the panel.
                frameGraphLegend(d, small),
              ],
            ),
            ...widget.sections(context, p),
          ],
        ),
      ),
    );
  }
}

/// A collapsible panel section. Its open state is kept in [open] by [id],
/// which defaults to the title. The state survives rebuilds, collapses and
/// scrolling.
class PanelSection extends StatelessWidget {
  PanelSection(
    this.title, {
    required this.open,
    required this.children,
    this.initiallyExpanded = true,
    String? id,
  }) : id = id ?? title,
       super(key: ValueKey(id ?? title));
  final String title, id;
  final Map<String, bool> open;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(title, style: Theme.of(context).textTheme.labelLarge),
    initiallyExpanded: open[id] ?? initiallyExpanded,
    onExpansionChanged: (v) => open[id] = v,
    dense: true,
    visualDensity: VisualDensity.compact,
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 6),
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    shape: const Border(),
    collapsedShape: const Border(),
    children: children,
  );
}
