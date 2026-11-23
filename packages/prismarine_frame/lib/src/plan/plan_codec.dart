import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:prismarine_kept/prismarine_kept.dart';

import 'frame_plan.dart';
import 'plan_codec_types.dart';

export 'plan_codec_types.dart';

part 'plan_codec_rows.dart';

/// Writes frame plans for a [PlanReader] on another isolate.
///
/// The objects that the frame runner keys its GPU objects and lookups on,
/// such as byte blocks, samplers, file and constant textures and inline
/// register maps, are sent once and then by id. The plan of the reader
/// shares them as the plan of the builder does. A byte block that is sent
/// again by id is compared with the copy sent. A block changed in place is
/// sent again under a new id. A frame role (FrameRole) is sent by name once
/// and its bytes with each plan. A draw sent in two messages in a row is
/// kept on both sides and sent by id after that. Its resources then cross
/// once. Everything else goes by value.
class PlanWriter {
  /// True when each message goes through a SendPort, whose send copies the
  /// blocks at once. The builder may then change them in place in the next
  /// frame without a copy by the writer.
  final bool sentThroughPort;

  PlanWriter({this.sentThroughPort = false, this.store});

  /// The store of the bytes of frame roles, or null to copy them into the
  /// message. The own blocks of a draw go in the message. Kept draws, passes
  /// and rows hold their blocks on the reader for as long as they exist
  /// there, which no message count bounds. The store frees a block by
  /// message.
  final PlanBlockStore? store;

  /// The address of the role block of each id in [store], which the writer
  /// frees, or 0 for none.
  final _native = <int>[];

  /// The role blocks in [store] by the bytes object of the builder, apart
  /// from [_ids]. A draw that binds the same object directly gets a block of
  /// its own. A kept draw holds its block for as long as the reader keeps
  /// the draw, past any plan. A role block is freed once no running plan
  /// refers to it.
  final _roleIds = HashMap<Uint8List, int>.identity();

  /// Frees the role blocks once the reader has run every plan before
  /// [message] that it will run.
  void release(int message) => store?.release(message);

  final _ids = LinkedHashMap<Object, int>.identity();
  final _objects = <Object?>[];
  final _lastUse = <int>[];

  /// The hash of the bytes sent for each id of a byte block. [_sentLength]
  /// holds their length, -1 for an object that is not a block with a copy
  /// sent. A block changed in place is sent again.
  var _sent = Int64List(1024);
  final _sentLength = <int>[];

  /// The message in which the block of each id was last sent or found the
  /// same as sent. A plan is whole when it is written. A block bound again
  /// in the same message, such as a camera or scene block bound by every
  /// draw, is compared once.
  final _checked = <int>[];
  final _table = PlanIds();
  int _message = 0;

  /// The ids of the blocks and objects that a draw or dispatch refers to
  /// while it is written by value ([_naming]).
  var _named = Int32List(256);
  int _nNamed = 0;
  bool _naming = false;

  /// The ids of the references of each kept draw or dispatch. A reference to
  /// the draw marks them used too. A block that a kept draw still binds is
  /// then not swept and sent again when a new draw binds it.
  final _kids = <Int32List?>[];

  var _ints = Int64List(4096);
  int _ni = 0;
  var _doubles = Float64List(1024);
  int _nd = 0;
  var _strings = <String>[];

  /// The id of every string sent. The reader keeps the same table. A string
  /// crosses once and reads back as the same object each frame, which the
  /// pipeline and binding lookups of the runner compare by identity first.
  final _stringIds = <String, int>{};
  var _bytes = <Uint8List>[];
  var _dropped = <int>[];

  /// The draws and dispatches sent by value in the last message and in this
  /// one. One seen in both messages is kept.
  var _lastDraws = LinkedHashSet<Object>.identity();
  var _nowDraws = LinkedHashSet<Object>.identity();

  /// The rows of each pass as sent by [_rows].
  final _sentRows = <String, _SentRows>{};

  /// Writes the rows of [r] as a change to the rows of the reader. It writes
  /// the rows whose draw is not the one sent under their id and then the
  /// ids gone since. The first time the rows of a pass are sent, the reader
  /// starts its table afresh. The id and plan lists sent last, sent again
  /// (keptRowSet), change nothing.
  void _rows(RenderPassPlan r) {
    final rows = r.rows;
    if (rows == null) {
      _int(0);
      return;
    }
    final fresh = !_sentRows.containsKey(r.name);
    final sent = _sentRows[r.name] ??= _SentRows();
    _int(fresh ? 2 : 1);
    final changed = _changedRows..clear();
    if (!identical(rows.ids, sent.ids) || !identical(rows.plans, sent.plans)) {
      sent
        ..ids = rows.ids
        ..plans = rows.plans;
      final stamp = ++sent.stamp;
      final byId = sent.rows;
      for (var i = 0; i < rows.ids.length; i++) {
        final id = rows.ids[i], plan = rows.plans[i];
        final had = byId[id];
        if (had == null) {
          changed.add(i);
          byId[id] = _SentRow(plan, stamp);
          continue;
        }
        // The changed rows are found in place without a record per row.
        if (!identical(had.plan, plan)) changed.add(i);
        had
          ..plan = plan
          ..stamp = stamp;
      }
    }
    _int(changed.length);
    for (var k = 0; k < changed.length; k++) {
      final i = changed[k];
      _int(rows.ids[i]);
      _draw(rows.plans[i]);
    }
    final gone = _goneRows..clear();
    _goneStamp = sent.stamp;
    sent.rows.forEach(_goneOne_);
    _int(gone.length);
    for (var k = 0; k < gone.length; k++) {
      sent.rows.remove(gone[k]);
      _int(gone[k]);
    }
    // The bounds of a changed row go with it. The culling values go with
    // every message.
    final bounds = rows.bounds;
    _int(bounds == null ? 0 : 1);
    if (bounds != null) {
      for (var k = 0; k < changed.length; k++) {
        final i = changed[k];
        for (var j = 0; j < 10; j++) {
          _double(bounds[i * 10 + j]);
        }
      }
    }
    final params = rows.params;
    _int(params?.length ?? -1);
    if (params != null) {
      for (var i = 0; i < params.length; i++) {
        _double(params[i]);
      }
    }
  }

  final _changedRows = KeptList<int>(), _goneRows = KeptList<int>();
  int _goneStamp = 0;

  void _goneOne(int id, _SentRow row) {
    if (row.stamp != _goneStamp) _goneRows.add(id);
  }

  late final _goneOne_ = _goneOne;

  /// Writes [plan] and [draws] as one message. [plan] is null when no camera
  /// showed.
  PlanMessage write(FramePlan? plan, [List<DrawPlan> draws = const []]) {
    _message++;
    _ni = _nd = 0;
    _strings = [];
    _bytes = [];
    _dropped = [];
    final last = _lastDraws;
    _lastDraws = _nowDraws;
    _nowDraws = last..clear();
    if (_message % planKeep == 0) _sweep();
    _sweepBlocks();
    final restart = _stringIds.length >= planMaxStrings;
    if (restart) _stringIds.clear();
    _int(restart ? 1 : 0);
    if (plan == null) {
      _int(0);
    } else {
      _int(1);
      _plan(plan);
    }
    _int(draws.length);
    for (final d in draws) {
      _draw(d);
    }
    for (final id in _dropped) {
      _table.free(id);
    }
    return PlanMessage(
      TransferableTypedData.fromList([Int64List.sublistView(_ints, 0, _ni)]),
      _ni,
      _doubles.sublist(0, _nd),
      _strings,
      _bytes,
      Int32List.fromList(_dropped),
      _message,
    );
  }

  /// The number of objects in the table now.
  int get tableSize => _ids.length + _roleIds.length;

  void _sweep() {
    final before = _message - planKeep;
    for (var id = 0; id < _objects.length; id++) {
      final o = _objects[id];
      if (o != null && _lastUse[id] <= before) _drop(id);
    }
  }

  /// Drops the byte blocks, the ids with a copy sent, that were unused in the
  /// last [planKeepBlocks] messages.
  void _sweepBlocks() {
    final before = _message - planKeepBlocks;
    final lengths = _sentLength, lastUse = _lastUse;
    for (var id = 0; id < lengths.length; id++) {
      if (lengths[id] >= 0 && lastUse[id] <= before) _drop(id);
    }
  }

  void _drop(int id) {
    if (_native[id] case final a when a != 0) {
      store!.drop(a, _message);
      _native[id] = 0;
      final o = _objects[id];
      if (o is Uint8List && _roleIds[o] == id) _roleIds.remove(o);
    } else {
      _ids.remove(_objects[id]);
    }
    _objects[id] = null;
    _sentLength[id] = -1;
    _kids[id] = null;
    _dropped.add(id);
  }

  void _int(int v) {
    if (_ni == _ints.length) {
      _ints = Int64List(_ni * 2)..setAll(0, _ints);
    }
    _ints[_ni++] = v;
  }

  void _double(double v) {
    if (_nd == _doubles.length) {
      _doubles = Float64List(_nd * 2)..setAll(0, _doubles);
    }
    _doubles[_nd++] = v;
  }

  void _string(String s) {
    var id = _stringIds[s];
    if (id == null) {
      _stringIds[s] = id = _stringIds.length;
      _strings.add(s);
    }
    _int(id);
  }

  void _stringOrNull(String? s) {
    if (s == null) {
      _int(-1);
    } else {
      _string(s);
    }
  }

  void _intOrNull(int? v) {
    _int(v == null ? 0 : 1);
    if (v != null) _int(v);
  }

  void _doubleList(List<double>? v) {
    if (v == null) {
      _int(-1);
      return;
    }
    _int(v.length);
    for (final d in v) {
      _double(d);
    }
  }

  void _stringList(List<String> v) {
    _int(v.length);
    for (final s in v) {
      _string(s);
    }
  }

  /// Returns true and writes the reference when [o] was sent and is kept.
  bool _known(Object o) {
    final id = _ids[o];
    if (id == null) return false;
    _int(tagRef);
    _int(id);
    _lastUse[id] = _message;
    _name(id);
    if (_kids[id] case final kids?) {
      for (var i = 0; i < kids.length; i++) {
        _lastUse[kids[i]] = _message;
      }
    }
    return true;
  }

  void _name(int id) {
    if (!_naming) return;
    if (_nNamed == _named.length) {
      _named = Int32List(_nNamed * 2)..setAll(0, _named);
    }
    _named[_nNamed++] = id;
  }

  /// Starts to collect the references of a draw or dispatch written by
  /// value.
  void _nameFrom() {
    _naming = true;
    _nNamed = 0;
  }

  /// Ends the collection and gives [o] its id when it is kept, with its
  /// references.
  void _keepNamed(Object o, bool again) {
    _naming = false;
    if (!again) return;
    final id = _keep(o);
    _kids[id] = _named.sublist(0, _nNamed);
  }

  /// Gives [o], just written with its tag and then its parts, its id. The id
  /// comes after those of its parts, as the reader makes it after reading
  /// them.
  int _keep(Object o) => _keepBlock(o, 0, -1);

  /// Keeps a block sent by value with its [hash] and [length], as [_keep]
  /// does.
  int _keepBlock(Object o, int hash, int length) {
    final id = _newId(o, hash, length);
    _ids[o] = id;
    return id;
  }

  /// Returns a table id for [o], recorded as a reference. A block has its
  /// [hash] and [length].
  int _newId(Object o, int hash, int length) {
    final id = _table.take();
    if (id >= _sent.length) {
      _sent = Int64List(id * 2)..setRange(0, _sent.length, _sent);
    }
    while (_objects.length <= id) {
      _objects.add(null);
      _lastUse.add(0);
      _sentLength.add(-1);
      _checked.add(0);
      _native.add(0);
      _kids.add(null);
    }
    _objects[id] = o;
    _lastUse[id] = _message;
    _sent[id] = hash;
    _sentLength[id] = length;
    _native[id] = 0;
    _checked[id] = _message;
    _kids[id] = null;
    _name(id);
    return id;
  }

  void _block(Uint8List? b) {
    if (b == null) {
      _int(tagNull);
      return;
    }
    if (FrameRole.of(b) case final role?) {
      if (_known(b)) return;
      _int(tagRole);
      _string(role.name);
      _keep(b);
      return;
    }
    final id = _ids[b];
    if (id != null) {
      if (_checked[id] == _message ||
          (_sentLength[id] == b.length && _sent[id] == _hash(b))) {
        _int(tagRef);
        _int(id);
        _lastUse[id] = _message;
        _checked[id] = _message;
        _name(id);
        return;
      }
      _drop(id);
    }
    _int(tagBytes);
    _int(_bytes.length);
    // The reader gets the bytes as they are now. The send of a port copies
    // them, else a copy goes here. A view crosses a port with the whole
    // buffer that it views. A view of part of a buffer therefore goes as a
    // copy of its own bytes.
    // alloc: a block sent anew is copied anyway, .buffer reveals a view
    final whole = b.lengthInBytes == b.buffer.lengthInBytes;
    // alloc: a block sent anew, as before, or the own bytes of a view
    _bytes.add(sentThroughPort && whole ? b : Uint8List.fromList(b));
    _keepBlock(b, _hash(b), b.length);
  }

  late final _bufferOne_ = _bufferOne;
  late final _roleOne_ = _roleOne;
  late final _retainedOne_ = _retainedOne;

  void _retainedOne(String pass, int stamp) {
    _string(pass);
    _int(stamp);
  }

  void _bufferOne(String key, BufferSpec value) {
    _string(key);
    // By value. The runner uploads [BufferSpec.initial] each frame and its
    // bytes go through the block check.
    _block(value.initial);
    _int(value.size << 1 | (value.readBack ? 1 : 0));
  }

  void _roleOne(Uint8List key, Uint8List bytes) {
    _block(key);
    _roleBytes(key, bytes);
  }

  void _plan(FramePlan p) {
    // The targets of the last plan again, as in most frames, go as −1. The
    // reader then gives its last map again.
    if (_sameTargets(p.targets)) {
      _int(-1);
    } else {
      _int(p.targets.length);
      for (final key in p.targets.keys) {
        final value = p.targets[key]!;
        _string(key);
        _targetSpec(value);
      }
    }
    _lastTargets = p.targets;
    // The map is walked by forEach through kept tear-offs, without an
    // iterator.
    _int(p.buffers.length);
    p.buffers.forEach(_bufferOne_);
    _int(p.frameBlocks.length);
    p.frameBlocks.forEach(_roleOne_);
    _int(p.retained.length);
    p.retained.forEach(_retainedOne_);
    _int(p.passes.length);
    for (var i = 0; i < p.passes.length; i++) {
      switch (p.passes[i]) {
        case final RenderPassPlan r:
          if (_passKept(i, r)) continue;
          _string(r.name);
          _int(r.colors.length);
          r.colors.forEach(_attachment);
          if (r.depth case final d?) {
            _attachment(d);
          } else {
            _int(tagNull);
          }
          _int(r.draws.length);
          r.draws.forEach(_draw);
          _rows(r);
          if (_passIds[i] == -2) _passIds[i] = _keep(r);
        case final DispatchPlan c:
          _dispatch(c);
      }
    }
  }

  /// The targets of the last plan.
  Map<String, TargetSpec>? _lastTargets;

  bool _sameTargets(Map<String, TargetSpec> now) {
    final last = _lastTargets;
    if (last == null || last.length != now.length) return false;
    if (identical(last, now)) return true;
    for (final key in now.keys) {
      final a = last[key], b = now[key]!;
      if (a == null ||
          a.width != b.width ||
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
    return true;
  }

  /// The bytes of each role as last sent, by id.
  final _roleSent = HashMap<Uint8List, int>.identity();

  /// Writes the bytes [b] of [role] for this frame. It writes the bytes last
  /// sent for the role again when [b] holds the same bytes. The role of the
  /// reader then keeps its bytes object. Otherwise it writes [b] as a block.
  void _roleBytes(Uint8List role, Uint8List b) {
    if (store case final st? when b.isNotEmpty) {
      _roleNative(st, role, b);
      return;
    }
    if (!_ids.containsKey(b)) {
      final id = _roleSent[role];
      if (id != null &&
          id < _objects.length &&
          _objects[id] != null &&
          _sentLength[id] == b.length &&
          _sent[id] == _hash(b)) {
        _int(tagRef);
        _int(id);
        _lastUse[id] = _message;
        _checked[id] = _message;
        _name(id);
        return;
      }
    }
    _block(b);
    if (_ids[b] case final id?) _roleSent[role] = id;
  }

  /// Writes the bytes [b] of [role] into [st], as [_roleBytes] does. The
  /// bytes last sent for the role or for this object go by id. Otherwise a
  /// copy goes into [st]. The old copy of an object changed in place is
  /// dropped.
  void _roleNative(PlanBlockStore st, Uint8List role, Uint8List b) {
    final h = _hash(b);
    final known = _roleIds[b];
    int? same;
    if (known != null) {
      if (_checked[known] == _message ||
          (_sentLength[known] == b.length && _sent[known] == h)) {
        same = known;
      } else {
        _drop(known);
      }
    } else if (_roleSent[role] case final id?
        when id < _objects.length &&
            _objects[id] != null &&
            _sentLength[id] == b.length &&
            _sent[id] == h) {
      same = id;
    }
    if (same != null) {
      _int(tagRef);
      _int(same);
      _lastUse[same] = _message;
      _checked[same] = _message;
      return;
    }
    final address = st.put(b);
    _int(tagNative);
    _int(address);
    _int(b.length);
    final id = _newId(b, h, b.length);
    _roleIds[b] = id;
    _native[id] = address;
    _roleSent[role] = id;
  }

  /// The render passes of the last message by position in the plan, with
  /// the id of each once kept. The id is -1 when not kept and -2 when kept
  /// since this message.
  final _passes = <RenderPassPlan?>[];
  final _passIds = <int>[];

  /// The message in which each of [_passes] was seen. Only the pass of the
  /// last message is compared. A builder writes the draw list of a
  /// published pass again two publishes later.
  final _passSeen = <int>[];

  /// Writes the pass [r] at [at] in the plan. A pass with the same name,
  /// attachments and draw objects as the pass sent there last time goes by
  /// its id. The pass of the reader is then the same object as before. A
  /// pass seen the same twice in a row is kept on both sides after that.
  /// Passes with rows go by value, since their rows change apart from the
  /// pass.
  bool _passKept(int at, RenderPassPlan r) {
    while (_passes.length <= at) {
      _passes.add(null);
      _passIds.add(-1);
      _passSeen.add(-1);
    }
    final last = _passSeen[at] == _message - 1 ? _passes[at] : null;
    _passes[at] = r;
    _passSeen[at] = _message;
    // A pass with rows is the same while its rows are the same object too.
    // A published row set is not written again.
    final same =
        last != null && identical(last.rows, r.rows) && _samePass(last, r);
    if (!same) {
      // The draws and rows go into the same pass object of the reader. A
      // pass whose culling values change each frame takes this path.
      if (last != null && r.rows != null && _passRows(at, last, r)) {
        return true;
      }
      // A kept pass with a few draws changed, such as the draws of a moved
      // object, goes as an edit. The pass of the reader stays the same
      // object.
      if (last != null && r.rows == null && _passEdit(at, last, r)) {
        return true;
      }
      // The draws go whole into the same pass object of the reader, for a
      // pass whose draw count changed.
      if (last != null && r.rows == null && _passReshape(at, last, r)) {
        return true;
      }
      // The pass is kept from its first frame. The frames after it send the
      // pass as an edit or a reshape, or as a rows reshape for a pass with
      // rows. A pass that changes every frame is kept as well.
      return _keepNew(at, r);
    }
    final id = _passIds[at];
    if (id >= 0 && identical(_objects[id], _keptPass[at])) {
      _int(tagRef);
      _int(id);
      _lastUse[id] = _message;
      // The draws stay in both tables while a message refers to the pass. A
      // pass that changes later still refers to them by id.
      final draws = r.draws;
      for (var i = 0; i < draws.length; i++) {
        if (_ids[draws[i]] case final k?) _lastUse[k] = _message;
      }
      return true;
    }
    return _keepNew(at, r);
  }

  /// Writes [r] whole as the pass kept at [at] and gives it its id once it
  /// is written.
  bool _keepNew(int at, RenderPassPlan r) {
    _passIds[at] = -2;
    while (_keptPass.length <= at) {
      _keptPass.add(null);
    }
    _keptPass[at] = r;
    _int(tagRenderKept);
    return false;
  }

  /// The pass object each kept id was given for, by position.
  final _keptPass = <RenderPassPlan?>[];

  static bool _samePass(RenderPassPlan a, RenderPassPlan b) {
    if (!_sameShape(a, b)) return false;
    for (var i = 0; i < a.draws.length; i++) {
      if (!identical(a.draws[i], b.draws[i])) return false;
    }
    return true;
  }

  /// Returns true for the same name, attachments and draw count.
  static bool _sameShape(RenderPassPlan a, RenderPassPlan b) =>
      a.draws.length == b.draws.length && _sameAttachments(a, b);

  /// Returns true for the same name and attachments.
  static bool _sameAttachments(RenderPassPlan a, RenderPassPlan b) {
    if (a.name != b.name ||
        a.colors.length != b.colors.length ||
        !_sameAttachment(a.depth, b.depth)) {
      return false;
    }
    for (var i = 0; i < a.colors.length; i++) {
      if (!_sameAttachment(a.colors[i], b.colors[i])) return false;
    }
    return true;
  }

  static bool _sameAttachment(Attachment? a, Attachment? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.target != b.target ||
        a.mip != b.mip ||
        a.layer != b.layer ||
        a.srgb != b.srgb ||
        a.clearDepth != b.clearDepth ||
        a.clearStencil != b.clearStencil) {
      return false;
    }
    final x = a.clear, y = b.clear;
    if (x == null || y == null) return x == null && y == null;
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  /// Writes a dispatch as a draw goes. A dispatch sent in the last message
  /// and in this one is kept on both sides and sent by id after that.
  void _dispatch(DispatchPlan c) {
    if (_known(c)) return;
    final again = _lastDraws.contains(c);
    _nowDraws.add(c);
    _int(again ? tagDispatchKept : tagDispatch);
    _nameFrom();
    _string(c.name);
    _string(c.shader);
    _int(c.groups.length);
    c.groups.forEach(_int);
    _resources(c.resources);
    _bufferRefOrNull(c.indirect);
    _keepNamed(c, again);
  }

  void _targetSpec(TargetSpec s) {
    _int(tagTargetSpec);
    _int(s.width);
    _int(s.height);
    _string(s.format);
    _int(s.layers);
    _int(s.mips);
    _int(s.samples);
    _int(
      (s.storage ? 1 : 0) | (s.volume ? 2 : 0) | (s.initial != null ? 4 : 0),
    );
    if (s.initial case final i?) _block(i);
  }

  void _attachment(Attachment a) {
    _int(tagAttachment);
    _string(a.target);
    _int(a.mip);
    _int(a.layer);
    _int(a.srgb ? 1 : 0);
    _doubleList(a.clear);
    _int(a.clearDepth == null ? 0 : 1);
    if (a.clearDepth case final d?) _double(d);
    _intOrNull(a.clearStencil);
  }

  void _draw(DrawPlan d) {
    if (_known(d)) return;
    final again = _lastDraws.contains(d);
    _nowDraws.add(d);
    _int(again ? tagDrawKept : tagDraw);
    _nameFrom();
    _string(d.vertex);
    _stringOrNull(d.pixel);
    _geometry(d.geometry);
    _state(d.state);
    _doubleList(d.viewport);
    _resources(d.vertexResources);
    _resources(d.pixelResources);
    _string(d.label);
    _int(d.stencilRef);
    _keepNamed(d, again);
  }

  // The maps are walked by forEach through tear-offs made once, without
  // iterators.
  void _resources(StageResources r) {
    _int(r.blocks.length);
    r.blocks.forEach(_blockEntry_);
    _int(r.textures.length);
    r.textures.forEach(_textureEntry_);
    _int(r.samplers.length);
    r.samplers.forEach(_samplerEntry_);
    _int(r.storage.length);
    r.storage.forEach(_storageEntry_);
  }

  void _blockEntry(String key, Uint8List value) {
    _string(key);
    _block(value);
  }

  void _textureEntry(String key, TextureRef value) {
    _string(key);
    _texture(value);
  }

  void _samplerEntry(int key, SamplerState value) {
    _int(key);
    _sampler(value);
  }

  void _storageEntry(String key, StorageRef value) {
    _string(key);
    _storage(value);
  }

  late final _blockEntry_ = _blockEntry;
  late final _textureEntry_ = _textureEntry;
  late final _samplerEntry_ = _samplerEntry;
  late final _storageEntry_ = _storageEntry;

  void _texture(TextureRef t) {
    switch (t) {
      case FileTexture(:final stem, :final srgb):
        if (_known(t)) return;
        _int(tagFile);
        _string(stem);
        _int(srgb ? 1 : 0);
        _keep(t);
      case final TargetTexture x:
        _int(tagTarget);
        _string(x.target);
        _int(x.mip);
        _int(x.mips);
        _int(x.layer);
        _int(x.layers);
        _int(x.srgb ? 1 : 0);
      case BufferTexture(:final bytes, :final format):
        _int(tagBufferTex);
        _block(bytes);
        _string(format);
      case ConstantTexture(
        :final format,
        :final texel,
        :final type,
        :final width,
        :final height,
      ):
        if (_known(t)) return;
        _int(tagConstant);
        _block(texel);
        _string(format);
        _string(type);
        _int(width ?? 0);
        _int(height ?? 0);
        _keep(t);
      case BufferTextureRef(:final ref):
        _int(tagBufferTexRef);
        _bufferRef(ref);
    }
  }

  void _storage(StorageRef s) {
    switch (s) {
      case final BufferRef r:
        _bufferRef(r);
      case InlineBuffer(:final bytes, :final format):
        _int(tagInlineBuffer);
        _block(bytes);
        _stringOrNull(format);
      case ImageRef(:final target, :final mip, :final layer):
        _int(tagImage);
        _string(target);
        _int(mip);
        _int(layer);
    }
  }

  void _bufferRefOrNull(BufferRef? r) {
    if (r == null) {
      _int(tagNull);
    } else {
      _bufferRef(r);
    }
  }

  void _bufferRef(BufferRef r) {
    _int(tagBufferRef);
    _string(r.buffer);
    _int(r.offset);
    _intOrNull(r.size);
    _stringOrNull(r.format);
  }

  void _sampler(SamplerState s) {
    if (_known(s)) return;
    _int(tagSampler);
    _int((s.minLinear ? 1 : 0) | (s.magLinear ? 2 : 0) | (s.mipLinear ? 4 : 0));
    _stringList(s.address);
    _int(s.anisotropy);
    _stringOrNull(s.compare);
    _double(s.minLod);
    _double(s.maxLod);
    _double(s.lodBias);
    _string(s.border);
    _keep(s);
  }

  void _state(DrawState s) {
    _int(tagState);
    _int(s.blends.length);
    s.blends.forEach(_blend);
    if (s.stencil case final st?) {
      _stencil(st);
    } else {
      _int(tagNull);
    }
    _string(s.cull);
    _int(
      (s.frontCounterClockwise ? 1 : 0) |
          (s.depthTest ? 2 : 0) |
          (s.depthWrite ? 4 : 0),
    );
    _string(s.depthFunc);
    _double(s.depthBias);
    _double(s.slopeScaledDepthBias);
    _double(s.depthBiasClamp);
    _string(s.topology);
  }

  void _blend(Blend b) {
    _int(tagBlend);
    _int(b.enabled ? 1 : 0);
    _stringList(b.color);
    _stringList(b.alpha);
    _int(b.writeMask);
  }

  void _stencil(Stencil s) {
    _int(tagStencil);
    _string(s.func);
    _string(s.passOp);
    _int(s.readMask);
    _int(s.writeMask);
  }

  void _geometry(DrawGeometry g) {
    switch (g) {
      case final DrawMeshGeometry m:
        _int(tagMesh);
        _string(m.mesh);
        _int(m.ibuffer);
        _int(m.firstIndex);
        _int(m.indexCount);
        _int(m.instances);
        _bufferRefOrNull(m.indirect);
        _int(m.streams.length);
        for (final MapEntry(:key, value: (ref, stride, format))
            in m.streams.entries) {
          _int(key);
          _bufferRef(ref);
          _int(stride);
          _string(format);
        }
      case final InlineGeometry i:
        _int(tagInline);
        _block(i.bytes);
        _block(i.indices);
        _registers(i.registers);
        _int(i.stride);
        _int(i.vertexCount);
        _int(i.instances);
      case ScreenGeometry(:final vertexCount, :final instances):
        _int(tagScreen);
        _int(vertexCount);
        _int(instances);
    }
  }

  void _registers(Map<int, (String, int)> r) {
    if (_known(r)) return;
    _int(tagRegisters);
    _int(r.length);
    for (final MapEntry(:key, value: (format, offset)) in r.entries) {
      _int(key);
      _string(format);
      _int(offset);
    }
    _keep(r);
  }
}
