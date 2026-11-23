import 'dart:isolate';
import 'dart:typed_data';

/// One frame's plan (and draws to make ready) as it crosses to another
/// isolate: integer, double, string and byte tapes ([PlanWriter] writes
/// them, [PlanReader] reads them in the same order). Plain typed data and
/// strings, so a SendPort copies it as a few blocks; the integer tape, the
/// largest, crosses as transferable bytes outside the Dart heap (one copy,
/// where a list and its send copy were two on the heap a frame).
final class PlanMessage {
  PlanMessage(
    this._ints,
    this.intCount,
    this.doubles,
    this.strings,
    this.bytes,
    this.dropped, [
    this.index = 0,
  ]);
  final TransferableTypedData _ints;

  /// The writer's count of messages at this one (PlanWriter.release).
  final int index;
  final int intCount;

  /// The integer tape, taken over on first read (on the reading isolate;
  /// a message is read once).
  late final Int64List ints = _ints.materialize().asInt64List(0, intCount);
  final Float64List doubles;

  /// The strings new to the reader's string table, in id order.
  final List<String> strings;

  /// The byte blocks new to the reader. They stay on the Dart heap: kept
  /// draws bind a block for many frames, and as transferable (external)
  /// bytes every block promoted waited for an old-space collection, which
  /// grew external memory to 240 MB and a 128 ms finalize (perf).
  final List<Uint8List> bytes;

  /// Ids freed after this message, in order (both sides reuse them alike).
  final Int32List dropped;
}

// What the integer tape holds before each value: no value, an object sent
// before (its id follows), or an object of one of the shared kinds.
const tagNull = 0, tagRef = 1;
const tagBytes = 2, tagSampler = 3, tagBlend = 4, tagStencil = 5;
const tagState = 6, tagMesh = 7, tagInline = 8, tagScreen = 9;
const tagFile = 10, tagTarget = 11, tagBufferTex = 12;
const tagConstant = 13, tagBufferTexRef = 14, tagBufferRef = 15;
const tagInlineBuffer = 16, tagImage = 17, tagTargetSpec = 18;
const tagRole = 19, tagAttachment = 20, tagRegisters = 21;
const tagRender = 22, tagDispatch = 23;

/// A draw by value, and a draw by value that both sides keep by id.
const tagDraw = 24, tagDrawKept = 25;

/// A dispatch by value that both sides keep by id.
const tagDispatchKept = 26;

/// A render pass by value that both sides keep by id.
const tagRenderKept = 27;

/// A block in the writer's [PlanBlockStore]: its address and length.
const tagNative = 28;

/// A kept render pass with some of its draws replaced: its id, then each
/// changed draw's place and the draw.
const tagRenderEdit = 29;

/// A kept render pass with its draws sent again whole (the same attachments,
/// another count, or too many changed for an edit): its id, the count, then
/// each draw, most by id.
const tagRenderReshape = 30;

/// A kept render pass with rows, its draws and rows sent again: its id, the
/// draw count and each draw (most by id), then its rows as a new pass's
/// (their changes since last sent).
const tagRenderRows = 31;

/// Memory outside the Dart heap that a writer puts frame roles' bytes in,
/// read in place by the reader on another isolate of the process: a role's
/// bytes are new most frames (palettes, the rows of moved objects, the camera),
/// and as message bytes each was copied by the send (perf: the build
/// isolate's largest allocation). Only plans name a role's block, so it
/// stays until both tables dropped it and the reader's side ran every plan
/// that could name it ([release]).
abstract interface class PlanBlockStore {
  /// A copy of [b]'s bytes: its address.
  int put(Uint8List b);

  /// The block at [address] is no longer named from message [message] on.
  void drop(int address, int message);

  /// No plan before message [message] is read any more: blocks dropped by
  /// then are freed.
  void release(int message);
}

/// How many messages an object may go unused before both sides drop it.
const planKeep = 30;

/// The same for a byte block, swept every message: a block no draw names
/// any more (the object block of a moving object in a frame before) is dropped
/// before a collection can promote its copies on both sides (perf: they
/// were most of what each young collection promoted).
const planKeepBlocks = 4;

/// How many strings both sides' string tables hold before the writer
/// starts them again (a message says so first).
const planMaxStrings = 1 << 16;

/// The ids both sides give objects: a dropped id is reused, last dropped
/// first, so the reader's table follows the writer's without being told.
final class PlanIds {
  final _free = <int>[];
  int _next = 0;

  int take() => _free.isNotEmpty ? _free.removeLast() : _next++;
  void free(int id) => _free.add(id);
}
