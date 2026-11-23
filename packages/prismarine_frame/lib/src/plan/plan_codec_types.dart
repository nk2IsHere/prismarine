import 'dart:isolate';
import 'dart:typed_data';

/// The plan of one frame and the draws to make ready as they cross to
/// another isolate. The message holds integer, double, string and byte
/// tapes. [PlanWriter] writes them and [PlanReader] reads them in the same
/// order. A SendPort copies the plain typed data and strings as a few
/// blocks. The integer tape, the largest, crosses as transferable bytes
/// outside the Dart heap.
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

  /// The count of messages of the writer at this one, for
  /// PlanWriter.release.
  final int index;
  final int intCount;

  /// The integer tape, taken over on the first read by the reading isolate.
  /// A message is read once.
  late final Int64List ints = _ints.materialize().asInt64List(0, intCount);
  final Float64List doubles;

  /// The strings new to the string table of the reader, in id order.
  final List<String> strings;

  /// The byte blocks new to the reader. They stay on the Dart heap. Kept
  /// draws bind a block for many frames. A block as transferable bytes would
  /// wait for an old-space collection once promoted.
  final List<Uint8List> bytes;

  /// The ids freed after this message, in order. Both sides reuse them
  /// alike.
  final Int32List dropped;
}

// The tags that the integer tape holds before each value. A tag marks no
// value, an object sent before with its id after the tag or an object of one
// of the shared kinds.
const tagNull = 0, tagRef = 1;
const tagBytes = 2, tagSampler = 3, tagBlend = 4, tagStencil = 5;
const tagState = 6, tagMesh = 7, tagInline = 8, tagScreen = 9;
const tagFile = 10, tagTarget = 11, tagBufferTex = 12;
const tagConstant = 13, tagBufferTexRef = 14, tagBufferRef = 15;
const tagInlineBuffer = 16, tagImage = 17, tagTargetSpec = 18;
const tagRole = 19, tagAttachment = 20, tagRegisters = 21;
const tagRender = 22, tagDispatch = 23;

/// A draw by value and a draw by value that both sides keep by id.
const tagDraw = 24, tagDrawKept = 25;

/// A dispatch by value that both sides keep by id.
const tagDispatchKept = 26;

/// A render pass by value that both sides keep by id.
const tagRenderKept = 27;

/// A block in the [PlanBlockStore] of the writer, with its address and
/// length.
const tagNative = 28;

/// A kept render pass with some of its draws replaced. Its id follows, then
/// the place of each changed draw and the draw.
const tagRenderEdit = 29;

/// A kept render pass with its draws sent again whole, for the same
/// attachments with another count or too many changes for an edit. Its id
/// follows, then the count and each draw, most of them by id.
const tagRenderReshape = 30;

/// A kept render pass with rows, its draws and rows sent again. Its id
/// follows, then the draw count and each draw, most of them by id. The rows
/// follow as for a new pass, as their changes since they were last sent.
const tagRenderRows = 31;

/// Memory outside the Dart heap that holds the bytes of frame roles of a
/// writer. The reader on another isolate of the process reads it in place.
/// Only plans refer to the block of a role. The block stays until both
/// tables dropped it and the reader has run every plan that could refer to
/// it ([release]).
abstract interface class PlanBlockStore {
  /// Copies the bytes of [b] and returns the address of the copy.
  int put(Uint8List b);

  /// Drops the block at [address]. No message from [message] onward uses it.
  void drop(int address, int message);

  /// Frees the blocks dropped before [message], since no plan before
  /// [message] is read any more.
  void release(int message);
}

/// The number of messages that an object may go unused before both sides
/// drop it.
const planKeep = 30;

/// The number of messages for a byte block, swept every message. A block
/// that no draw binds any more, such as the object block of a moving object
/// in an earlier frame, is dropped before a collection can promote its copies
/// on both sides.
const planKeepBlocks = 4;

/// The number of strings that the string tables of both sides hold before
/// the writer starts them again. A message marks the restart first.
const planMaxStrings = 1 << 16;

/// The ids that both sides give objects. A dropped id is reused, the last
/// dropped first. The table of the reader then follows the table of the
/// writer without a message.
final class PlanIds {
  final _free = <int>[];
  int _next = 0;

  int take() => _free.isNotEmpty ? _free.removeLast() : _next++;
  void free(int id) => _free.add(id);
}
