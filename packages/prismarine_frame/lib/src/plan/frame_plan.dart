import 'dart:collection';
import 'dart:typed_data';

/// What S2's frame draws, pass by pass, as plain data: built on the CPU from
/// the session's state the way Minecraft2.exe fills its constant buffers
/// (or, for checks, from an oracle capture), and run on the GPU by
/// mcsm_look_scene's S2 frame. Keeping the plan apart from the GPU lets the
/// CPU side be compared with the exe's own buffers without a GPU
/// (formats/s2/frame.md).
class FramePlan {
  FramePlan(
    this.targets,
    this.passes, {
    Map<String, BufferSpec>? buffers,
    Map<Uint8List, Uint8List>? frameBlocks,
    this.retained = const {},
  }) : buffers = buffers ?? {},
       frameBlocks = frameBlocks ?? HashMap.identity();

  /// Every render target the frame uses, by name.
  final Map<String, TargetSpec> targets;
  final List<PassPlan> passes;

  /// GPU buffers the frame's passes write and read (the cascade and culling
  /// computes' outputs, indirect arguments, skinned vertices), by name.
  final Map<String, BufferSpec> buffers;

  /// The bytes of each frame role the draws bind this frame, by the role's
  /// block ([FrameRole.block]).
  final Map<Uint8List, Uint8List> frameBlocks;

  /// Passes whose work a runner may leave out, by pass name: a stamp of
  /// what the pass makes (0: none). A pass with the stamp it last ran
  /// with, on targets not made again since, would write what its targets
  /// already hold: a local light's shadow while nothing it sees changes
  /// (perf: the sea temple's ten lights' maps, blurs and mips were 3.2 of
  /// a frame's 14.9 ms of GPU). The plan is whole either way; a runner
  /// that has not run a stamp runs the pass.
  final Map<String, int> retained;

  /// Constant block [b] of a draw as this frame binds it: a role's bytes
  /// for the frame, any other block as it is.
  Uint8List block(Uint8List b) => b.isEmpty ? frameBlocks[b] ?? b : b;
}

/// A constant block a draw names by its role in the frame (the camera's,
/// the scene's, a light group's) rather than by its bytes, which change
/// from frame to frame: a draw that binds only roles and blocks kept from
/// frame to frame stays the same object while its agent holds still, and
/// the plan codec sends it once. In a draw's resources a role stands as
/// [block], an empty block of its own; the plan gives its bytes for the
/// frame ([FramePlan.frameBlocks]). One role per name in an isolate.
final class FrameRole {
  factory FrameRole(String name) => _roles[name] ??= FrameRole._(name);
  FrameRole._(this.name) {
    _roleBlocks[block] = this;
  }
  final String name;
  final Uint8List block = Uint8List(0);

  /// The role [b] stands for, or null when it is a block of bytes.
  static FrameRole? of(Uint8List b) => b.isEmpty ? _roleBlocks[b] : null;
}

final _roles = <String, FrameRole>{};
final _roleBlocks = HashMap<Uint8List, FrameRole>.identity();

/// A GPU buffer of [size] bytes, filled with [initial] at the start of the
/// frame when given (the exe uploads it from the CPU), else left as the
/// last frame left it; with [readBack] the runner hands its bytes as the
/// frame left them to its reader once the GPU is done (an Enlighten duster
/// pass's visibility words).
class BufferSpec {
  const BufferSpec(this.size, {this.initial, this.readBack = false});
  final int size;
  final Uint8List? initial;
  final bool readBack;
}

/// A range of a frame buffer: as a texel buffer of [format], a raw or
/// structured storage buffer (no format), an indirect argument block or a
/// vertex stream.
class BufferRef extends StorageRef {
  const BufferRef(this.buffer, {this.offset = 0, this.size, this.format});
  final String buffer;
  final int offset;

  /// Bytes from [offset]; null: to the buffer's end.
  final int? size;
  final String? format;
}

/// A texel buffer read from a frame buffer.
class BufferTextureRef extends TextureRef {
  const BufferTextureRef(this.ref);
  final BufferRef ref;
}

/// A render target (or a compute pass's storage image): size, format (the exe's DXGI name without the
/// `DXGI_FORMAT_` prefix, e.g. `R11G11B10_FLOAT`), layers, mips and samples.
class TargetSpec {
  const TargetSpec(
    this.width,
    this.height,
    this.format, {
    this.layers = 1,
    this.mips = 1,
    this.samples = 1,
    this.storage = false,
    this.volume = false,
    this.initial,
  });
  final int width, height, layers, mips, samples;
  final String format;

  /// Texels the runner uploads into mip 0 at the start of each frame, layer
  /// after layer, rows top first, without padding (a frame role's block:
  /// FramePlan.block gives this frame's bytes); null: the target keeps
  /// what passes draw into it. An Enlighten system's output is one
  /// (formats/s2/enlighten.md "The renderer's contract").
  final Uint8List? initial;

  /// A 3D texture of [layers] depth slices rather than an array.
  final bool volume;

  /// Whether a compute pass writes it as a storage image.
  final bool storage;

  bool get isDepth => format.startsWith('D');
}

/// One attachment of a pass: a target (a mip and layer of it) and what the
/// pass does with its contents first.
class Attachment {
  const Attachment(
    this.target, {
    this.mip = 0,
    this.layer = 0,
    this.clear,
    this.clearDepth,
    this.clearStencil,
    this.srgb = false,
  });
  final String target;
  final int mip, layer;

  /// Drawn through an sRGB view of an 8-bit RGBA target: written values are
  /// encoded (and blended linear), as the exe's sRGB render-target views
  /// do.
  final bool srgb;

  /// A colour clear (RGBA), or null to load.
  final List<double>? clear;
  final double? clearDepth;
  final int? clearStencil;
}

sealed class PassPlan {
  PassPlan(this.name);
  final String name;
}

/// A render pass: colour attachments, an optional depth attachment and its
/// draws in order.
class RenderPassPlan extends PassPlan {
  RenderPassPlan(super.name, this.colors, this.depth, this.draws);
  final List<Attachment> colors;
  final Attachment? depth;
  final List<DrawPlan> draws;

  /// The pass's kept rows (the own-renderer design, R0c), drawn before
  /// [draws]: draws neither culled nor ordered on the CPU, which the codec
  /// sends only when they change and the runner draws in pulled form,
  /// culled on the GPU. Null for a pass of [draws] only.
  RowSet? rows;

  /// What a frame runner keeps with this pass (its attachments as the
  /// engine's objects): the runner's, not part of the plan. A pass the
  /// codec keeps is the same object from frame to frame.
  Object? runnerState;

  /// Changes to [draws] in place so far (the codec's edits of a kept
  /// pass), for what a runner keeps with it.
  int version = 0;

  /// Everything the pass draws: its [rows]' draws, then [draws]; made
  /// again when the rows or the [version] changed (a kept pass's codec
  /// edits).
  List<DrawPlan> get allDraws {
    final r = rows;
    if (r == null) return draws;
    if (!identical(_allOf, r) || _allAt != version) {
      _allOf = r;
      _allAt = version;
      _all = r.withDraws(draws);
    }
    return _all!;
  }

  RowSet? _allOf;
  int _allAt = -1;
  List<DrawPlan>? _all;
}

/// A pass's rows: each row's draw and its id, which holds while the builder
/// keeps the draw's batch (a changed draw keeps its row's id).
class RowSet {
  RowSet(this.ids, this.plans, {this.bounds, this.params});
  final List<int> ids;
  final List<DrawPlan> plans;

  /// Per row, what a pass's own culling reads besides the draw (10 floats a
  /// row: the key light's casters, their mesh's bounding sphere and box).
  final Float32List? bounds;

  /// The pass's culling values this frame (the cascades' light rotation
  /// rows, the view's rectangle, the cascade rows).
  final Float32List? params;

  /// [plans] then [draws] ([RenderPassPlan.allDraws]): a view over both,
  /// the same object while [draws] is (perf: a pass's every draw copied
  /// each frame its draws changed). A reader's kept pass changes [draws]
  /// in place and moves its version, which its runner follows.
  List<DrawPlan> withDraws(List<DrawPlan> draws) {
    final had = _all;
    if (had != null && identical(had._b, draws)) return had;
    return _all = _Joined(plans, draws);
  }

  _Joined? _all;

  /// [had]'s view when it is over the same plans (a set made anew for
  /// new culling values).
  void keepDrawsOf(RowSet had) {
    if (!identical(had.plans, plans)) return;
    _all = had._all;
  }
}

/// Two lists read as one, unmodifiable.
final class _Joined extends ListBase<DrawPlan> {
  _Joined(this._a, this._b);
  final List<DrawPlan> _a, _b;

  @override
  int get length => _a.length + _b.length;

  @override
  set length(int n) => throw UnsupportedError('a joined list');

  @override
  DrawPlan operator [](int i) {
    final n = _a.length;
    return i < n ? _a[i] : _b[i - n];
  }

  @override
  void operator []=(int i, DrawPlan d) =>
      throw UnsupportedError('a joined list');
}

/// A compute dispatch.
class DispatchPlan extends PassPlan {
  DispatchPlan(
    super.name,
    this.shader,
    this.groups,
    this.resources, {
    this.indirect,
  });
  final String shader;
  final List<int> groups;
  final StageResources resources;

  /// Group counts read on the GPU from three uints here (DispatchIndirect).
  final BufferRef? indirect;

  /// What a frame runner keeps with this dispatch (its GPU reads and
  /// writes): the runner's, not part of the plan.
  Object? runnerState;
}

/// Where a texture or texel buffer a shader reads comes from.
sealed class TextureRef {
  const TextureRef();
}

/// A slice texture by stem (`textures/<stem>.json` and `.bin`), as sRGB
/// when the exe's view is.
class FileTexture extends TextureRef {
  const FileTexture(this.stem, {this.srgb = false});
  final String stem;
  final bool srgb;
}

/// One of the frame's targets, a range of its mips and layers.
class TargetTexture extends TextureRef {
  const TargetTexture(
    this.target, {
    this.mip = 0,
    this.mips = 1,
    this.layer = 0,
    this.layers = 1,
    this.srgb = false,
  });
  final String target;
  final int mip, mips, layer, layers;

  /// Read through an sRGB view of an 8-bit RGBA target (texels decoded).
  final bool srgb;
}

/// A texel buffer's contents (format as a DXGI name); [bytes] may be a
/// frame role's block (FrameRole), whose bytes the plan gives for the
/// frame (FramePlan.block).
class BufferTexture extends TextureRef {
  const BufferTexture(this.bytes, this.format);
  final Uint8List bytes;
  final String format;
}

/// A texture filled with constant texels, for an input a pass does not have
/// yet (format as a DXGI name, the bytes of one texel), or with [width] ×
/// [height] texels the frame makes from data (a particle file's property
/// maps), row by row in [texel].
class ConstantTexture extends TextureRef {
  const ConstantTexture(
    this.format,
    this.texel, {
    this.type = '2d',
    this.width,
    this.height,
  });
  final String format;
  final Uint8List texel;
  final String type;

  /// The size of an image from data; null: one texel everywhere.
  final int? width, height;
}

/// A sampler state as Direct3D 11 describes it.
class SamplerState {
  const SamplerState({
    this.minLinear = true,
    this.magLinear = true,
    this.mipLinear = true,
    this.address = const ['wrap', 'wrap', 'wrap'],
    this.anisotropy = 1,
    this.compare,
    this.minLod = 0,
    this.maxLod = 1000,
    this.lodBias = 0,
    this.border = 'transparentBlack',
  });
  final bool minLinear, magLinear, mipLinear;

  /// U, V, W: `wrap`, `clamp`, `mirror`, `border`.
  final List<String> address;
  final int anisotropy;

  /// A comparison function name (`less`, `lessEqual`, …) or null.
  final String? compare;
  final double minLod, maxLod, lodBias;
  final String border;
}

/// A read-write resource a compute shader binds (`u#`, or a raw or
/// structured buffer `RawT#`/`RawU#`).
sealed class StorageRef {
  const StorageRef();
}

/// A buffer holding [bytes] for this dispatch only (an input the exe filled
/// on the CPU, or a written buffer whose result nothing in the plan reads);
/// [format] names the texel format of a storage texel buffer.
class InlineBuffer extends StorageRef {
  const InlineBuffer(this.bytes, {this.format});
  final Uint8List bytes;
  final String? format;
}

/// A mip and layer of a frame target, written as a storage image.
class ImageRef extends StorageRef {
  const ImageRef(this.target, {this.mip = 0, this.layer = 0});
  final String target;
  final int mip, layer;
}

/// What a shader stage binds: constant buffers by block name, textures by
/// GLSL name, samplers by `s#` register and storage resources by name.
class StageResources {
  StageResources({
    Map<String, Uint8List>? blocks,
    Map<String, TextureRef>? textures,
    Map<int, SamplerState>? samplers,
    Map<String, StorageRef>? storage,
  }) : blocks = blocks ?? {},
       textures = textures ?? {},
       samplers = samplers ?? {},
       storage = storage ?? {};
  final Map<String, Uint8List> blocks;
  final Map<String, TextureRef> textures;
  final Map<int, SamplerState> samplers;
  final Map<String, StorageRef> storage;

  /// What a frame runner keeps with these (their bindings in a shader's
  /// order): the runner's, not part of the plan.
  Object? runnerState;
}

/// Blend state of one colour target.
class Blend {
  const Blend({
    this.enabled = false,
    this.color = const ['one', 'zero', 'add'],
    this.alpha = const ['one', 'zero', 'add'],
    this.writeMask = 0xf,
  });
  final bool enabled;

  /// source factor, destination factor, operation.
  final List<String> color, alpha;
  final int writeMask;
}

/// A draw's stencil test, the same for both faces: the comparison of the
/// draw's reference with the stored value (both under [readMask]), and the
/// operation where the stencil and depth tests pass, writing [writeMask]'s
/// bits; a failing test keeps the stored value.
class Stencil {
  const Stencil({
    this.func = 'always',
    this.passOp = 'keep',
    this.readMask = 0xff,
    this.writeMask = 0xff,
  });

  /// `always`, `equal`, … as [DrawState.depthFunc] names them.
  final String func;

  /// `keep` or `replace`.
  final String passOp;
  final int readMask, writeMask;
}

/// Raster and depth state of a draw.
class DrawState {
  const DrawState({
    this.cull = 'back',
    this.frontCounterClockwise = false,
    this.depthTest = true,
    this.depthWrite = true,
    this.depthFunc = 'lessEqual',
    this.blends = const [],
    this.depthBias = 0,
    this.slopeScaledDepthBias = 0,
    this.depthBiasClamp = 0,
    this.topology = 'triangleList',
    this.stencil,
  });
  final String cull;
  final bool frontCounterClockwise, depthTest, depthWrite;
  final String depthFunc;
  final List<Blend> blends;
  final double depthBias, slopeScaledDepthBias, depthBiasClamp;
  final String topology;

  /// The stencil test, with [DrawPlan.stencilRef]; null: off.
  final Stencil? stencil;
}

/// Where a draw's vertices come from.
sealed class DrawGeometry {
  const DrawGeometry();
}

/// A mesh's shipped streams (`meshes/<stem>.glb`): index buffer [ibuffer]
/// from [firstIndex], [indexCount] indices.
class DrawMeshGeometry extends DrawGeometry {
  const DrawMeshGeometry(
    this.mesh,
    this.ibuffer,
    this.firstIndex,
    this.indexCount, {
    this.instances = 1,
    this.indirect,
    this.streams = const {},
  });
  final String mesh;
  final int ibuffer, firstIndex, indexCount, instances;

  /// Index count, instance count, first index, base vertex and first
  /// instance read on the GPU here (DrawIndexedInstancedIndirect); the
  /// index range above still picks the bound index buffer's start.
  final BufferRef? indirect;

  /// Vertex inputs fed from frame buffers instead of the mesh, by input
  /// register: the buffer range, its stride and the input's DXGI format
  /// (the skinned positions a compute pass writes).
  final Map<int, (BufferRef, int, String)> streams;
}

/// A draw of vertices given inline: one vertex buffer of [stride]-byte
/// vertices whose attributes are fed to the vertex shader's inputs by
/// register ([registers]: input register → (DXGI format, byte offset)); the
/// exe's post passes draw its four-vertex screen quad this way.
class InlineGeometry extends DrawGeometry {
  const InlineGeometry(
    this.bytes,
    this.stride,
    this.registers,
    this.vertexCount, {
    this.instances = 1,
    this.indices,
  });
  final Uint8List bytes;
  final int stride, vertexCount, instances;
  final Map<int, (String, int)> registers;

  /// U16 indices, when the draw is indexed ([vertexCount] of them).
  final Uint8List? indices;
}

/// A full-screen draw of [vertexCount] vertices without buffers (a pass
/// that builds its vertices from SV_VertexID).
class ScreenGeometry extends DrawGeometry {
  const ScreenGeometry(this.vertexCount, {this.instances = 1});
  final int vertexCount, instances;
}

/// One draw: its shaders (ids into the slice's `shaders/`), geometry,
/// state, viewport and each stage's resources.
class DrawPlan {
  DrawPlan({
    required this.vertex,
    required this.pixel,
    required this.geometry,
    required this.state,
    required this.viewport,
    required this.vertexResources,
    required this.pixelResources,
    this.label = '',
    this.stencilRef = 0,
  });
  final String vertex;
  final String? pixel;
  final DrawGeometry geometry;
  final DrawState state;

  /// x, y, width, height, min depth, max depth.
  final List<double> viewport;
  final StageResources vertexResources, pixelResources;
  final String label;
  final int stencilRef;

  /// What a frame runner keeps with this draw (its pipeline, vertex
  /// sources and targets read): the runner's, not part of the plan, so a
  /// kept draw finds them without a lookup per frame.
  Object? runnerState;
}
