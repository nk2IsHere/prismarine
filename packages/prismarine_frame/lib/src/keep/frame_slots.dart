import 'dart:collection';
import 'dart:typed_data';

import 'package:prismarine_kept/prismarine_kept.dart';

import '../plan/frame_plan.dart';

/// What a view's frames are built in and published from, kept from frame
/// to frame (the retained-passes design): the pass list,
/// targets, buffers and role maps as scratch, each render pass built in
/// its slot's scratch pass, and the plan's objects published by
/// comparison. A published object is never written after the plan is
/// handed on; the same content next frame publishes the same object, so
/// the codec, the reader and the runner compare by identity only.
final class FrameSlots {
  /// The frame's passes as built (scratch passes and the dispatches).
  final passes = KeptList<PassPlan>();
  final targets = KeptMap<String, TargetSpec>();

  /// A builder's dispatch counts by name, kept and cleared each frame.
  final dispatchCounts = KeptMap<String, int>();

  /// A builder's warnings, kept and cleared each frame (read once the
  /// frame is built).
  final warnings = KeptList<String>();
  final buffers = KeptMap<String, BufferSpec>();

  /// The role maps, three in turn: a plan's map holds until the third plan
  /// after it, as the runner keeps three frames in flight.
  final _roles = [
    KeptMap<Uint8List, Uint8List>.identity(),
    KeptMap<Uint8List, Uint8List>.identity(),
    KeptMap<Uint8List, Uint8List>.identity(),
  ];
  int _frame = -1;

  /// The frame's stamps (FramePlan.retained), in the role maps' turn.
  // alloc: once per slots, as its three maps
  final _retained = [
    // alloc: once per slots
    KeptMap<String, int>(),
    // alloc: once per slots
    KeptMap<String, int>(),
    // alloc: once per slots
    KeptMap<String, int>(),
  ];
  Map<String, int> get retained => _retained[_frame % 3];

  /// Each role's bytes in turn ([roleCopy]), by the role's block.
  final _rings = HashMap<Uint8List, BlockRing>.identity();

  /// [role]'s bytes for this frame, [scratch]'s copied into the role's own
  /// ring of three blocks: last frame's block while the bytes hold, else
  /// the next block, written in place. A block a plan holds is written
  /// again only after two more changes, three frames on at the soonest:
  /// the role maps' turn (perf: a block per changing role a frame).
  Uint8List roleCopy(FrameRole role, Uint8List bytes) =>
      (_rings[role.block] ??= BlockRing()).give(bytes, _frame)!;

  /// The frame being built, counted from 0 ([BlockRing.give]'s turns).
  int get frame => _frame;

  /// Render pass slots by name, in their order in the frame, and how many
  /// of each name this frame has used.
  final _byName = <String, List<_PassSlot>>{};
  final _used = KeptMap<String, int>();

  final _published = KeptList<PassPlan>();
  List<PassPlan>? _lastPasses;
  Map<String, TargetSpec>? _lastTargets;
  Map<String, BufferSpec>? _lastBuffers;

  /// Starts a frame: the scratch cleared, the next role map in turn.
  Map<Uint8List, Uint8List> begin() {
    passes.clear();
    targets.clear();
    buffers.clear();
    _used.clear();
    dispatchCounts.clear();
    warnings.clear();
    _frame++;
    _retained[_frame % 3].clear();
    return _roles[_frame % 3]..clear();
  }

  /// The scratch pass for this frame's next pass named [name], added to
  /// the frame's passes: its slot's one again while its attachments hold,
  /// emptied.
  RenderPassPlan pass(String name, List<Attachment> colors, Attachment? depth) {
    final p = slotPass(name, colors, depth);
    passes.add(p);
    return p;
  }

  /// [pass]'s scratch pass, which the caller adds to the frame's passes in
  /// its place (a builder that makes a scene's render textures after the
  /// scene's own passes and draws them before). The slot is the name's next occurrence in the order taken.
  RenderPassPlan slotPass(
    String name,
    List<Attachment> colors,
    Attachment? depth,
  ) {
    final at = _used[name] ?? 0;
    _used[name] = at + 1;
    final slots = _byName[name] ??= [];
    if (slots.length == at) slots.add(_PassSlot());
    final slot = slots[at];
    var p = slot.scratch;
    if (p == null ||
        !_sameAttachments(p.colors, colors) ||
        !_sameAttachment(p.depth, depth)) {
      slot.draws.clear();
      p = slot.scratch = RenderPassPlan(name, colors, depth, slot.draws);
    } else {
      slot.draws.clear();
      p.rows = null;
    }
    return p;
  }

  /// The plan of the frame built: each scratch pass replaced by its slot's
  /// published pass (last frame's while the same), the pass list, targets
  /// and buffers last frame's while the same.
  FramePlan publish(Map<Uint8List, Uint8List> roles) {
    final out = _published..clear();
    for (var i = 0; i < passes.length; i++) {
      final p = passes[i];
      out.add(p is RenderPassPlan ? _publish(p) : p);
    }
    // Last frame's list while the same, else the next of three in turn
    // (perf: a copy of the pass list each frame a pass changed).
    final had = _lastPasses;
    final List<PassPlan> list;
    if (had != null && _samePasses(had, out)) {
      list = had;
    } else {
      list = _passLists[_passTurn = (_passTurn + 1) % 3]
        ..clear()
        ..addAll(out);
      _lastPasses = list;
    }
    final t = _lastTargets = _sameTargets(_lastTargets, targets)
        ? _lastTargets!
        : Map.of(targets);
    final b = _lastBuffers = _sameBuffers(_lastBuffers, buffers)
        ? _lastBuffers!
        : Map.of(buffers);
    return FramePlan(
      t,
      list,
      buffers: b,
      frameBlocks: roles,
      retained: retained,
    );
  }

  /// [p] as published: last frame's pass while its targets, rows and draws
  /// are the same. A pass whose targets changed with the same draws (the
  /// main pass's glow mask, which moves off the G-buffer while motion blur
  /// reads its motion vectors) is published anew.
  RenderPassPlan _publish(RenderPassPlan p) {
    final slot = _slotOf(p);
    final had = slot.published;
    if (had != null &&
        _sameAttachments(had.colors, p.colors) &&
        _sameAttachment(had.depth, p.depth) &&
        identical(had.rows, p.rows) &&
        _sameDraws(had.draws, p.draws)) {
      return had;
    }
    final list = slot.lists[slot.turn = (slot.turn + 1) % 3]
      ..clear()
      ..addAll(p.draws);
    return slot.published = RenderPassPlan(p.name, p.colors, p.depth, list)
      ..rows = p.rows;
  }

  _PassSlot _slotOf(RenderPassPlan p) {
    final slots = _byName[p.name]!;
    for (var i = 0; i < slots.length; i++) {
      if (identical(slots[i].scratch, p)) return slots[i];
    }
    throw StateError('pass ${p.name} is not a slot pass');
  }

  final _passLists = [
    KeptList<PassPlan>(),
    KeptList<PassPlan>(),
    KeptList<PassPlan>(),
  ];
  int _passTurn = 0;

  static bool _samePasses(List<PassPlan> a, List<PassPlan> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameDraws(List<DrawPlan> a, List<DrawPlan> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameAttachments(List<Attachment> a, List<Attachment> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameAttachment(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameAttachment(Attachment? a, Attachment? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.target == b.target &&
        a.mip == b.mip &&
        a.layer == b.layer &&
        a.srgb == b.srgb &&
        a.clearDepth == b.clearDepth &&
        a.clearStencil == b.clearStencil &&
        _sameClear(a.clear, b.clear);
  }

  static bool _sameClear(List<double>? a, List<double>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i] || a[i].isNegative != b[i].isNegative) return false;
    }
    return true;
  }

  static bool _sameTargets(
    Map<String, TargetSpec>? had,
    KeptMap<String, TargetSpec> now,
  ) {
    if (had == null || had.length != now.length) return false;
    for (final key in now.keys) {
      final a = had[key], b = now[key]!;
      if (a == null) return false;
      if (identical(a, b)) continue;
      if (a.width != b.width ||
          a.height != b.height ||
          a.format != b.format ||
          a.layers != b.layers ||
          a.mips != b.mips ||
          a.samples != b.samples ||
          a.storage != b.storage ||
          a.volume != b.volume ||
          !identical(a.initial, b.initial)) {
        return false;
      }
    }
    return _sameOrder(had.keys, now.keys);
  }

  static bool _sameBuffers(
    Map<String, BufferSpec>? had,
    KeptMap<String, BufferSpec> now,
  ) {
    if (had == null || had.length != now.length) return false;
    for (final key in now.keys) {
      final a = had[key], b = now[key]!;
      if (a == null) return false;
      if (!identical(a, b) &&
          (a.size != b.size ||
              !identical(a.initial, b.initial) ||
              a.readBack != b.readBack)) {
        return false;
      }
    }
    return _sameOrder(had.keys, now.keys);
  }

  /// The same keys in the same order (a plan's maps are walked in order).
  static bool _sameOrder(Iterable<String> a, Iterable<String> b) {
    final x = a.iterator, y = b.iterator;
    while (x.moveNext()) {
      if (!y.moveNext() || x.current != y.current) return false;
    }
    return !y.moveNext();
  }
}

/// One render pass position: its scratch pass and draw list, and the pass
/// it published last.
final class _PassSlot {
  final draws = KeptList<DrawPlan>();
  RenderPassPlan? scratch, published;

  /// The published passes' draw lists, three in turn: a published pass's
  /// list is written again two publishes later, when no reader holds it
  /// (the plan codec compares a pass only with last message's; perf: a
  /// copy of a changed pass's draws each frame).
  final lists = [
    KeptList<DrawPlan>(),
    KeptList<DrawPlan>(),
    KeptList<DrawPlan>(),
  ];
  int turn = 0;
}

/// Three blocks, taken in turn for bytes that change from frame to frame:
/// the current block while the bytes hold, else the next block, written in
/// place. The ring turns at most once a frame, so a block given out is
/// written again only after two more changes, three frames on at the
/// soonest: a plan (and its role map) holds until the third plan after it
/// (perf: a block per change).
final class BlockRing {
  final _blocks = List<Uint8List?>.filled(3, null);
  int _at = 0;
  int _turned = -1;

  /// [bytes] in the ring for [frame]. A second change in the same frame
  /// writes the block of that frame again when [overwrite] (a role: only
  /// the last bytes count), else gives null (the caller keeps a block of
  /// its own).
  Uint8List? give(Uint8List bytes, int frame, {bool overwrite = true}) {
    final now = _blocks[_at];
    if (now != null && _same(now, bytes)) return now;
    if (_turned != frame) {
      _at = (_at + 1) % 3;
      _turned = frame;
    } else if (!overwrite) {
      return null;
    }
    var b = _blocks[_at];
    if (b == null || b.length != bytes.length) {
      // alloc: a ring's block of a new length
      b = _blocks[_at] = Uint8List(bytes.length);
    }
    return b..setAll(0, bytes);
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
