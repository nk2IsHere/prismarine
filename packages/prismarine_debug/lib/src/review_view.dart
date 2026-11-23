// The review: scrub the frame history while the game is paused, mark what's wrong on
// the frames (point, arrow, pen, box) with a note, and save it as an issue.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'frame_history.dart';
import 'issue.dart';
import 'png.dart';

/// What the review saves: the issue, and its PNGs by file name.
typedef ReviewSave =
    Future<String?> Function(
      Issue issue,
      Map<String, Uint8List> files,
      Uint8List? screenshot,
    );

class ReviewView extends StatefulWidget {
  const ReviewView({
    super.key,
    required this.history,
    required this.openedAt,
    required this.onSave,
    required this.onClose,
    this.autoSave = false,
    this.autoSaveNote = 'review self-test',
    this.emptyText = 'no frames kept',
  });

  final FrameHistory history;

  /// The game time when the review opened.
  final double openedAt;
  final ReviewSave onSave;
  final VoidCallback onClose;

  /// An unattended check: a test mark on the frame 10 back, then save.
  final bool autoSave;

  /// The note of [autoSave]'s test mark.
  final String autoSaveNote;

  /// The text in place of a frame's time while the history holds none.
  final String emptyText;

  @override
  State<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<ReviewView> {
  final _focus = FocusNode();
  final _note = TextEditingController();
  final _noteFocus = FocusNode();

  /// The shown frame, frames back from the newest.
  int _back = 0;
  ui.Image? _image;
  int? _imageBack;
  MarkTool _tool = MarkTool.point;

  /// Marks by game frame number (a mark belongs to the frame it's drawn on).
  final _marks = <int, List<Mark>>{};

  /// Notes by game frame number: the note box edits the shown frame's.
  final _notes = <int, String>{};

  /// Whether frame [frame] carries an issue (marks or a note).
  bool _isMarked(int frame) =>
      (_marks[frame] ?? const []).isNotEmpty ||
      (_notes[frame] ?? '').trim().isNotEmpty;

  /// The stroke being drawn (fractions of the frame).
  List<(double, double)>? _stroke;
  String? _status;
  bool _saving = false;

  FrameHistory get _h => widget.history;
  int get _count => _h.length;
  HistoryMeta get _meta => _h.metaAt(_back);
  List<Mark> get _frameMarks => _marks[_meta.frame] ??= [];

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    if (widget.autoSave) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoSave());
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _focus.dispose();
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  ui.Image? _shown() {
    if (_count == 0) return null;
    if (_imageBack != _back) {
      _image?.dispose();
      _image = _h.imageAt(_back);
      _imageBack = _back;
    }
    return _image;
  }

  /// Shows the frame [back] frames before the newest, with its own note.
  void _go(int back) => setState(() {
    _back = back.clamp(0, math.max(0, _count - 1));
    if (_count > 0) _note.text = _notes[_meta.frame] ?? '';
  });

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final step = hw.isShiftPressed ? 10 : 1;
    final cmd = hw.isMetaPressed || hw.isControlPressed;
    // Typing a note: every key is the text field's (digits, arrows, ⌘Z)
    // except save, and Escape, which leaves the field for the frame.
    if (_noteFocus.hasFocus) {
      if (cmd && k == LogicalKeyboardKey.keyS) {
        _save();
      } else if (k == LogicalKeyboardKey.escape) {
        _focus.requestFocus();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _go(_back + step);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _go(_back - step);
    } else if (k == LogicalKeyboardKey.escape) {
      widget.onClose();
    } else if (cmd && k == LogicalKeyboardKey.keyZ) {
      _undo();
    } else if (cmd && k == LogicalKeyboardKey.keyS) {
      _save();
    } else if (!cmd && _toolKeys.containsKey(k)) {
      setState(() => _tool = _toolKeys[k]!);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static final _toolKeys = {
    LogicalKeyboardKey.digit1: MarkTool.point,
    LogicalKeyboardKey.digit2: MarkTool.arrow,
    LogicalKeyboardKey.digit3: MarkTool.pen,
    LogicalKeyboardKey.digit4: MarkTool.box,
  };

  void _undo() {
    final list = _marks[_meta.frame];
    if (list != null && list.isNotEmpty) setState(list.removeLast);
  }

  // --- Drawing ---------------------------------------------------------------

  (double, double) _at(Offset p, Size s) =>
      Mark.normalize(p.dx, p.dy, s.width, s.height);

  void _down(Offset p, Size s) {
    if (_count == 0) return;
    setState(() => _stroke = [_at(p, s)]);
  }

  void _move(Offset p, Size s) {
    final st = _stroke;
    if (st == null) return;
    setState(() {
      if (_tool == MarkTool.pen) {
        st.add(_at(p, s));
      } else if (st.length == 1) {
        st.add(_at(p, s));
      } else {
        st[1] = _at(p, s);
      }
    });
  }

  void _up() {
    final st = _stroke;
    if (st == null) return;
    _stroke = null;
    final marks = _frameMarks;
    setState(() {
      switch (_tool) {
        case MarkTool.point:
          final n = _marks.values.fold<int>(
            0,
            (a, l) => a + l.where((m) => m.tool == MarkTool.point).length,
          );
          marks.add(Mark(MarkTool.point, [st.last], label: '${n + 1}'));
        case MarkTool.pen:
          if (st.length > 1) marks.add(Mark(MarkTool.pen, st));
        case MarkTool.arrow || MarkTool.box:
          if (st.length > 1) marks.add(Mark(_tool, [st.first, st.last]));
      }
    });
  }

  // --- Saving ----------------------------------------------------------------

  Future<void> _save() async {
    if (_saving || _count == 0) return;
    setState(() {
      _saving = true;
      _status = 'saving…';
    });
    final newestWall = _h.metaAt(0).wall;
    // The marked frames, oldest first; the shown frame when none is marked.
    final backs = <int>[
      for (var b = _count - 1; b >= 0; b--)
        if (_isMarked(_h.metaAt(b).frame)) b,
    ];
    if (backs.isEmpty) backs.add(_back);
    final frames = <IssueFrame>[];
    final files = <String, Uint8List>{};
    Uint8List? screenshot;
    for (final b in backs) {
      final meta = _h.metaAt(b);
      final marks = List<Mark>.of(_marks[meta.frame] ?? const []);
      final frame = IssueFrame(
        meta: meta,
        offset: meta.wall - newestWall,
        marks: marks,
        note: (_notes[meta.frame] ?? '').trim(),
      );
      frames.add(frame);
      final image = _h.imageAt(b);
      try {
        files['frame_${meta.frame}.png'] = await _png(image, const []);
        final marked = await _png(image, marks, caption: _caption(frame));
        files['frame_${meta.frame}.marked.png'] = marked;
        screenshot ??= marked;
      } finally {
        image.dispose();
      }
    }
    final issue = Issue(
      frames: frames,
      width: _h.width,
      height: _h.height,
      openedAt: widget.openedAt,
    );
    String? out;
    try {
      out = await widget.onSave(issue, files, screenshot);
    } catch (e) {
      out = null;
      if (mounted) setState(() => _status = 'save failed: $e');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (out != null) widget.onClose();
  }

  /// [image] with [marks] drawn, as a PNG (read back through a Picture;
  /// encoded on a worker isolate).
  Future<Uint8List> _png(
    ui.Image image,
    List<Mark> marks, {
    String? caption,
  }) async {
    final (w, h) = (image.width, image.height);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final size = Size(w.toDouble(), h.toDouble());
    canvas.drawImage(image, Offset.zero, Paint());
    paintMarks(canvas, size, marks);
    if (caption != null) paintCaption(canvas, size, caption);
    final pic = rec.endRecording();
    final out = await pic.toImage(w, h);
    pic.dispose();
    final raw = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    out.dispose();
    final bytes = TransferableTypedData.fromList([raw!.buffer.asUint8List()]);
    return Isolate.run(
      () => encodePng(bytes.materialize().asUint8List(), w, h),
    );
  }

  /// The marked PNG's caption: the frame's time code and its note.
  static String _caption(IssueFrame f) =>
      't ${f.meta.time.toStringAsFixed(2)} s · frame ${f.meta.frame} · '
      '${f.offset.toStringAsFixed(2)} s'
      '${f.note.isEmpty ? '' : ' — ${f.note}'}';

  Future<void> _autoSave() async {
    if (_count == 0) return;
    _go(math.min(10, _count - 1));
    _frameMarks
      ..add(Mark(MarkTool.point, [(0.5, 0.5)], label: '1'))
      ..add(Mark(MarkTool.box, [(0.25, 0.25), (0.75, 0.75)]));
    _notes[_meta.frame] = _note.text = widget.autoSaveNote;
    await _save();
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final image = _shown();
    final meta = _count == 0 ? null : _meta;
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    final marked = {
      for (var b = 0; b < _count; b++)
        if (_isMarked(_h.metaAt(b).frame)) b,
    };
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: ColoredBox(
        color: const Color(0xF0101114),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final size = c.biggest;
                      return MouseRegion(
                        cursor: SystemMouseCursors.precise,
                        child: Listener(
                          onPointerDown: (e) {
                            _focus.requestFocus();
                            _down(e.localPosition, size);
                          },
                          onPointerMove: (e) => _move(e.localPosition, size),
                          onPointerUp: (_) => _up(),
                          child: CustomPaint(
                            size: size,
                            painter: _FramePainter(
                              image,
                              meta == null ? const [] : _frameMarks,
                              _stroke,
                              _tool,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Material(
              color: const Color(0xFF1B1D22),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Older (←, Shift: 10)',
                          onPressed: () => _go(_back + 1),
                          icon: const Icon(Icons.chevron_left),
                          color: Colors.white,
                        ),
                        Expanded(
                          child: _Scrubber(
                            count: _count,
                            back: _back,
                            marked: marked,
                            onBack: _go,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Newer (→, Shift: 10)',
                          onPressed: () => _go(_back - 1),
                          icon: const Icon(Icons.chevron_right),
                          color: Colors.white,
                        ),
                        Flexible(
                          child: Text(
                            meta == null
                                ? widget.emptyText
                                : 't ${meta.time.toStringAsFixed(2)} s '
                                      '(${(meta.wall - _h.metaAt(0).wall).toStringAsFixed(2)} s, '
                                      'frame ${meta.frame}, ${_back + 1}/$_count)',
                            style: small,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    // Tools (wrap on a narrow window: a debug panel takes
                    // room), then the note with save and close.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final (t, label) in const [
                          (MarkTool.point, '1 Point'),
                          (MarkTool.arrow, '2 Arrow'),
                          (MarkTool.pen, '3 Pen'),
                          (MarkTool.box, '4 Box'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: _tool == t,
                              onSelected: (_) => setState(() => _tool = t),
                            ),
                          ),
                        TextButton(
                          onPressed: _undo,
                          child: const Text('Undo (⌘Z)'),
                        ),
                        TextButton(
                          onPressed: () => setState(_frameMarks.clear),
                          child: const Text('Clear frame'),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _note,
                            focusNode: _noteFocus,
                            onChanged: (v) {
                              if (_count == 0) return;
                              final was = _isMarked(_meta.frame);
                              _notes[_meta.frame] = v;
                              // The strip's dot comes and goes with it.
                              if (was != _isMarked(_meta.frame)) {
                                setState(() {});
                              }
                            },
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'What is wrong on this frame?',
                              hintStyle: TextStyle(color: Colors.white38),
                            ),
                            onSubmitted: (_) => _save(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_status case final s?)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(s, style: small),
                          ),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: const Text('Save issue (⌘S)'),
                        ),
                        const SizedBox(width: 4),
                        OutlinedButton(
                          onPressed: widget.onClose,
                          child: const Text('Close (Esc)'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frames as a strip: oldest left, newest right; marked frames dotted.
class _Scrubber extends StatelessWidget {
  const _Scrubber({
    required this.count,
    required this.back,
    required this.marked,
    required this.onBack,
  });

  final int count, back;
  final Set<int> marked;
  final ValueChanged<int> onBack;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      void at(Offset p) {
        if (count == 0) return;
        final i = (p.dx / c.maxWidth * count).floor().clamp(0, count - 1);
        onBack(count - 1 - i);
      }

      return GestureDetector(
        onTapDown: (d) => at(d.localPosition),
        onHorizontalDragUpdate: (d) => at(d.localPosition),
        child: CustomPaint(
          size: Size(c.maxWidth, 28),
          painter: _ScrubPainter(count, back, marked),
        ),
      );
    },
  );
}

class _ScrubPainter extends CustomPainter {
  _ScrubPainter(this.count, this.back, this.marked);

  final int count, back;
  final Set<int> marked;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 10, size.width, 8),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFF3A3D45),
    );
    if (count == 0) return;
    final w = size.width / count;
    double x(int b) => (count - 1 - b + 0.5) * w;
    final dot = Paint()..color = const Color(0xFFFFC107);
    for (final b in marked) {
      canvas.drawCircle(Offset(x(b), 6), 3, dot);
    }
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(x(back), 14),
        width: math.max(3, w),
        height: 20,
      ),
      Paint()..color = const Color(0xFF4FC3F7),
    );
  }

  @override
  bool shouldRepaint(_ScrubPainter old) =>
      old.count != count ||
      old.back != back ||
      old.marked.length != marked.length;
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.image, this.marks, this.stroke, this.tool);

  final ui.Image? image;
  final List<Mark> marks;
  final List<(double, double)>? stroke;
  final MarkTool tool;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    paintMarks(canvas, size, [...marks, ?_live()]);
  }

  /// The stroke being drawn, as the mark it will become.
  Mark? _live() {
    final s = stroke;
    if (s == null || s.isEmpty) return null;
    return switch (tool) {
      MarkTool.point => Mark(MarkTool.point, [s.last], label: '?'),
      MarkTool.pen => Mark(MarkTool.pen, s),
      MarkTool.arrow ||
      MarkTool.box => s.length < 2 ? null : Mark(tool, [s.first, s.last]),
    };
  }

  @override
  bool shouldRepaint(_FramePainter old) => true;
}

/// Draws [marks] over a [size] frame (the review and the saved PNGs).
void paintMarks(Canvas canvas, Size size, List<Mark> marks) {
  final unit = size.width / 800;
  final stroke = Paint()
    ..color = const Color(0xFFFF3B30)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3 * unit
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final halo = Paint()
    ..color = const Color(0xCC000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6 * unit
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  Offset p((double, double) q) => Offset(q.$1 * size.width, q.$2 * size.height);
  for (final m in marks) {
    final pts = [for (final q in m.points) p(q)];
    if (pts.isEmpty) continue;
    switch (m.tool) {
      case MarkTool.point:
        final c = pts.last;
        for (final paint in [halo, stroke]) {
          canvas.drawCircle(c, 14 * unit, paint);
        }
        final tp = TextPainter(
          text: TextSpan(
            text: m.label ?? '•',
            style: TextStyle(
              color: const Color(0xFFFF3B30),
              fontSize: 14 * unit,
              fontWeight: FontWeight.bold,
              shadows: const [Shadow(blurRadius: 3)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c + Offset(16 * unit, -tp.height - 8 * unit));
      case MarkTool.box:
        if (pts.length < 2) continue;
        final r = Rect.fromPoints(pts.first, pts.last);
        for (final paint in [halo, stroke]) {
          canvas.drawRect(r, paint);
        }
      case MarkTool.pen:
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final q in pts.skip(1)) {
          path.lineTo(q.dx, q.dy);
        }
        for (final paint in [halo, stroke]) {
          canvas.drawPath(path, paint);
        }
      case MarkTool.arrow:
        if (pts.length < 2) continue;
        final (a, b) = (pts.first, pts.last);
        final d = b - a;
        if (d.distance < 1) continue;
        final u = d / d.distance;
        final n = Offset(-u.dy, u.dx);
        final head = 16 * unit;
        final path = Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..moveTo(b.dx, b.dy)
          ..lineTo(
            (b - u * head + n * head * 0.6).dx,
            (b - u * head + n * head * 0.6).dy,
          )
          ..moveTo(b.dx, b.dy)
          ..lineTo(
            (b - u * head - n * head * 0.6).dx,
            (b - u * head - n * head * 0.6).dy,
          );
        for (final paint in [halo, stroke]) {
          canvas.drawPath(path, paint);
        }
    }
  }
}

/// A caption strip along the bottom of a [size] frame: [text] (the frame's
/// time code and note) on a dark band, so a saved frame explains itself.
void paintCaption(Canvas canvas, Size size, String text) {
  final unit = size.width / 800;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: 13 * unit),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 3,
    ellipsis: '…',
  )..layout(maxWidth: size.width - 16 * unit);
  final band = tp.height + 10 * unit;
  canvas.drawRect(
    Rect.fromLTWH(0, size.height - band, size.width, band),
    Paint()..color = const Color(0xB0000000),
  );
  tp.paint(canvas, Offset(8 * unit, size.height - band + 5 * unit));
}
