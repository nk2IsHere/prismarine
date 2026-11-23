// The review's data: the frame ring's indexing, the marks drawn on a frame and the issue written
// with a dump. Plain Dart, so its rules are tested without a GPU.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The slots of a fixed-size ring, newest first: [push] takes the next slot
/// (overwriting the oldest once full), [slotAt] maps "n frames back" to a
/// slot.
class RingIndex {
  RingIndex(this.capacity) : assert(capacity > 0);

  final int capacity;
  int _next = 0;
  int _length = 0;

  /// How many slots hold a frame.
  int get length => _length;

  /// The slot for a new frame.
  int push() {
    final slot = _next;
    _next = (_next + 1) % capacity;
    if (_length < capacity) _length++;
    return slot;
  }

  /// The slot [back] frames before the newest (0 = newest).
  int slotAt(int back) {
    RangeError.checkValidIndex(back, this, 'back', _length);
    return (_next - 1 - back) % capacity;
  }

  void clear() {
    _next = 0;
    _length = 0;
  }
}

/// What a frame in the ring was: its game time, game frame, wall time (the
/// app's clock, s) and the 3D scene shown.
class HistoryMeta {
  const HistoryMeta({
    required this.frame,
    required this.time,
    required this.wall,
    this.scene,
    this.render,
  });

  final int frame;
  final double time;
  final double wall;
  final String? scene;

  /// What the 3D frame was drawn with (the camera, the scene's fog), kept
  /// so a marked one-off frame can be told apart afterwards (a wrong camera
  /// or fog for one frame).
  final Map<String, Object?>? render;
}

/// The review's drawing tools.
enum MarkTool { point, arrow, pen, box }

/// One mark on a frame: its tool, its points as fractions (0–1) of the 16:9
/// frame (x right, y down), and a label (a point's number).
class Mark {
  Mark(this.tool, List<(double, double)> points, {this.label})
    : points = List.unmodifiable(points);

  final MarkTool tool;
  final List<(double, double)> points;
  final String? label;

  Map<String, Object?> toJson() => {
    'tool': tool.name,
    'points': [
      for (final (x, y) in points) [_r(x), _r(y)],
    ],
    if (label != null) 'label': label,
  };

  static Mark fromJson(Map<String, Object?> j) =>
      Mark(MarkTool.values.byName(j['tool']! as String), [
        for (final p in (j['points']! as List).cast<List>())
          ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ], label: j['label'] as String?);

  /// [x], [y] (pixels in a [width]×[height] frame) as a mark point.
  static (double, double) normalize(
    double x,
    double y,
    double width,
    double height,
  ) => ((x / width).clamp(0.0, 1.0), (y / height).clamp(0.0, 1.0));
}

double _r(double x) => (x * 1e4).roundToDouble() / 1e4;

/// A marked frame of an issue.
class IssueFrame {
  const IssueFrame({
    required this.meta,
    required this.offset,
    required this.marks,
    this.note = '',
  });

  final HistoryMeta meta;

  /// What is wrong on this frame (its marks and its time code).
  final String note;

  /// Seconds before the review opened (≤ 0).
  final double offset;
  final List<Mark> marks;

  Map<String, Object?> toJson() => {
    'frame': meta.frame,
    't': _r(meta.time),
    'wall': _r(meta.wall),
    'offset': _r(offset),
    if (meta.scene != null) 'scene': meta.scene,
    if (meta.render != null) 'render': meta.render,
    if (note.isNotEmpty) 'note': note,
    'image': 'frame_${meta.frame}.png',
    'marked': 'frame_${meta.frame}.marked.png',
    'marks': [for (final m in marks) m.toJson()],
  };
}

/// An issue as the review saves it next to a dump.
class Issue {
  const Issue({
    required this.frames,
    required this.width,
    required this.height,
    required this.openedAt,
  });

  /// The frames' notes, oldest first (each note belongs to its frame).
  String get note => [
    for (final f in frames)
      if (f.note.isNotEmpty) f.note,
  ].join('; ');

  /// The marked frames, oldest first (the shown frame when none is marked).
  final List<IssueFrame> frames;

  /// The ring's frame size.
  final int width, height;

  /// The game time at which the review opened.
  final double openedAt;

  Map<String, Object?> toJson() => {
    'note': note,
    'openedAt': _r(openedAt),
    'ring': {'width': width, 'height': height},
    'frames': [for (final f in frames) f.toJson()],
  };

  /// The README lines for [dir] (the dump's folder): per marked frame, its
  /// time, its note and the lines [commands] gives for it.
  List<String> readme(String dir, {IssueCommands? commands}) => [
    '',
    'Issue: ${note.isEmpty ? '(no note)' : note}',
    for (final f in frames) ...[
      '',
      'Frame ${f.meta.frame} at t ${f.meta.time.toStringAsFixed(3)} '
          '(${f.offset.toStringAsFixed(2)} s before the review, '
          '${f.marks.length} mark${f.marks.length == 1 ? '' : 's'}): '
          'frame_${f.meta.frame}.marked.png',
      if (f.note.isNotEmpty) '  note: ${f.note}',
      ...?commands?.call(dir, f),
    ],
  ];
}

/// The README lines that redo [frame] of an issue saved in [dir], such as
/// the commands that render it again.
typedef IssueCommands = List<String> Function(String dir, IssueFrame frame);

/// Writes [issue] into [dir], a dump's folder: [files] by name,
/// `issue.json` and the README lines appended to its README.
void writeIssue(
  String dir,
  Issue issue,
  Map<String, Uint8List> files, {
  IssueCommands? commands,
}) {
  for (final MapEntry(:key, :value) in files.entries) {
    File('$dir/$key').writeAsBytesSync(value);
  }
  File('$dir/issue.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(issue.toJson()),
  );
  File('$dir/README').writeAsStringSync(
    '${issue.readme(dir, commands: commands).join('\n')}\n',
    mode: FileMode.append,
  );
}
