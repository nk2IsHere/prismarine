// The data of the review, with the indexing of the frame ring, the marks
// drawn on a frame and the issue written with a dump. It is plain Dart and
// is tested without a GPU.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The slots of a fixed-size ring, newest first. [push] takes the next slot
/// and overwrites the oldest once the ring is full. [slotAt] maps a number
/// of frames back to a slot.
class RingIndex {
  RingIndex(this.capacity) : assert(capacity > 0);

  final int capacity;
  int _next = 0;
  int _length = 0;

  /// The number of slots that hold a frame.
  int get length => _length;

  /// Returns the slot for a new frame.
  int push() {
    final slot = _next;
    _next = (_next + 1) % capacity;
    if (_length < capacity) _length++;
    return slot;
  }

  /// Returns the slot [back] frames before the newest, where 0 is the newest.
  int slotAt(int back) {
    RangeError.checkValidIndex(back, this, 'back', _length);
    return (_next - 1 - back) % capacity;
  }

  void clear() {
    _next = 0;
    _length = 0;
  }
}

/// A frame in the ring with its game time, game frame, wall time in seconds
/// of the clock of the app and the 3D scene shown.
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

  /// The inputs of the 3D frame, such as the camera and the fog of the
  /// scene. A marked frame with a wrong camera or fog for one frame is then
  /// visible afterwards.
  final Map<String, Object?>? render;
}

/// The review's drawing tools.
enum MarkTool { point, arrow, pen, box }

/// One mark on a frame with its tool, its points as fractions from 0 to 1 of
/// the 16:9 frame with x right and y down. It has a label, such as the number
/// of a point.
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

  /// Returns the pixel [x], [y] of a [width]×[height] frame as a mark point.
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

  /// The note about the defect on this frame, its marks and its time code.
  final String note;

  /// The seconds before the review opened, 0 or less.
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

  /// The notes of the frames, oldest first. Each note belongs to its frame.
  String get note => [
    for (final f in frames)
      if (f.note.isNotEmpty) f.note,
  ].join('; ');

  /// The marked frames, oldest first, or the shown frame when none is
  /// marked.
  final List<IssueFrame> frames;

  /// The frame size of the ring.
  final int width, height;

  /// The game time at which the review opened.
  final double openedAt;

  Map<String, Object?> toJson() => {
    'note': note,
    'openedAt': _r(openedAt),
    'ring': {'width': width, 'height': height},
    'frames': [for (final f in frames) f.toJson()],
  };

  /// Returns the README lines for [dir], the folder of the dump. Each marked
  /// frame gets its time, its note and the lines that [commands] gives for
  /// it.
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

/// Writes [issue] into [dir], the folder of a dump. Writes [files] by name,
/// then `issue.json`, then appends the README lines to the README there.
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
