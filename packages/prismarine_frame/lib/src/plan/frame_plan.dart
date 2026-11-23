import 'dart:collection';
import 'dart:typed_data';

/// A frame's work, pass by pass, as plain data. A builder makes it on the
/// CPU and a frame runner records it on the GPU. A plan can be checked and
/// compared without a GPU.
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

  /// The GPU buffers that the passes of the frame write and read, by name,
  /// such as the outputs of culling computes, indirect arguments and skinned
  /// vertices.
  final Map<String, BufferSpec> buffers;

  /// The bytes of each frame role that the draws bind this frame, by the
  /// block of the role ([FrameRole.block]).
  final Map<Uint8List, Uint8List> frameBlocks;

  /// The passes whose work a runner may leave out, by pass name, each with a
  /// stamp of its output or 0 for none. A pass with the stamp of its last run,
  /// on targets not made again since, would write what its targets already
  /// hold, such as the shadow of a local light while nothing it sees
  /// changes. The plan is whole either way. A runner that has not run a stamp
  /// runs the pass.
  final Map<String, int> retained;

  /// Returns the constant block [b] of a draw as this frame binds it. A role
  /// gives its bytes for the frame and any other block is returned as it is.
  Uint8List block(Uint8List b) => b.isEmpty ? frameBlocks[b] ?? b : b;
}

/// A constant block that a draw binds by its role in the frame, such as the
/// block of the camera, the scene or a light group, in place of its bytes,
/// which change from frame to frame. A draw that binds only roles and kept
/// blocks stays the same object while the object it draws holds still. The
/// plan codec then sends it once. In the resources of a draw a role stands
/// as [block], an empty block of its own. The plan gives its bytes for the
/// frame ([FramePlan.frameBlocks]). An isolate has one role per name.
final class FrameRole {
  factory FrameRole(String name) => _roles[name] ??= FrameRole._(name);
  FrameRole._(this.name) {
    _roleBlocks[block] = this;
  }
  final String name;
  final Uint8List block = Uint8List(0);

  /// Returns the role of [b], or null when [b] is a block of bytes.
  static FrameRole? of(Uint8List b) => b.isEmpty ? _roleBlocks[b] : null;
}

final _roles = <String, FrameRole>{};
final _roleBlocks = HashMap<Uint8List, FrameRole>.identity();

/// A GPU buffer of [size] bytes. The CPU uploads [initial] at the start of
/// the frame when it is given. Otherwise the buffer keeps the contents of the
/// last frame. With [readBack] the runner passes the bytes at the end of the
/// frame to its reader once the GPU is done, such as the visibility words of
/// a compute pass.
class BufferSpec {
  const BufferSpec(this.size, {this.initial, this.readBack = false});
  final int size;
  final Uint8List? initial;
  final bool readBack;
}

/// A range of a frame buffer, used as a texel buffer of [format], as a raw or
/// structured storage buffer without a format, as an indirect argument block
/// or as a vertex stream.
class BufferRef extends StorageRef {
  const BufferRef(this.buffer, {this.offset = 0, this.size, this.format});
  final String buffer;
  final int offset;

  /// The bytes from [offset], or null for the rest of the buffer.
  final int? size;
  final String? format;
}

/// A texel buffer read from a frame buffer.
class BufferTextureRef extends TextureRef {
  const BufferTextureRef(this.ref);
  final BufferRef ref;
}

/// A render target or the storage image of a compute pass with its size,
/// format, layers, mips and samples. The format is a DXGI name without the
/// `DXGI_FORMAT_` prefix, such as `R11G11B10_FLOAT`.
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

  /// The texels that the runner uploads into mip 0 at the start of each
  /// frame, layer after layer, rows top first, without padding. It is the
  /// block of a frame role. FramePlan.block gives the bytes of this frame.
  /// Null when the target keeps what passes draw into it. A lightmap
  /// that the CPU computes each frame is an example.
  final Uint8List? initial;

  /// A 3D texture of [layers] depth slices rather than an array.
  final bool volume;

  /// True when a compute pass writes it as a storage image.
  final bool storage;

  bool get isDepth => format.startsWith('D');
}

/// One attachment of a pass, a mip and layer of a target, with the first
/// action of the pass on its contents.
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

  /// True when the pass draws through an sRGB view of an 8-bit RGBA target.
  /// Written values are encoded and blended linear, as sRGB render-target
  /// views do in Direct3D 11.
  final bool srgb;

  /// The RGBA colour of a clear, or null to load.
  final List<double>? clear;
  final double? clearDepth;
  final int? clearStencil;
}

sealed class PassPlan {
  PassPlan(this.name);
  final String name;
}

/// A render pass with colour attachments, an optional depth attachment and
/// its draws in order.
class RenderPassPlan extends PassPlan {
  RenderPassPlan(super.name, this.colors, this.depth, this.draws);
  final List<Attachment> colors;
  final Attachment? depth;
  final List<DrawPlan> draws;

  /// The kept rows of the pass, drawn before [draws]. Rows are draws that the
  /// CPU neither culls nor orders. The codec sends them only when they
  /// change. The runner draws them in pulled form, culled on the GPU. Null
  /// for a pass of [draws] only.
  RowSet? rows;

  /// The state that a frame runner keeps with this pass, such as its
  /// attachments as objects of the engine. It belongs to the runner and not
  /// to the plan. A pass that the codec keeps is the same object from frame
  /// to frame.
  Object? runnerState;

  /// The count of the changes to [draws] in place so far, such as the edits
  /// of the codec to a kept pass. A runner checks it against its state.
  int version = 0;

  /// Every draw of the pass, the draws of its [rows] and then [draws]. The
  /// list is made again when the rows or the [version] changed.
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

/// The rows of a pass, with the draw and the id of each row. The id holds
/// while the builder keeps the batch of the draw. A changed draw keeps the
/// id of its row.
class RowSet {
  RowSet(this.ids, this.plans, {this.bounds, this.params});
  final List<int> ids;
  final List<DrawPlan> plans;

  /// The values that the culling of the pass reads for each row besides the
  /// draw. A row has 10 floats for the casters of the key light, the
  /// bounding sphere and the box of their mesh.
  final Float32List? bounds;

  /// The culling values of the pass this frame, such as the light rotation
  /// rows of a shadow cascade, the rectangle of the view and the cascade
  /// rows.
  final Float32List? params;

  /// Returns [plans] and then [draws] for [RenderPassPlan.allDraws] as a
  /// view over both. The view is the same object while [draws] is. The kept
  /// pass of a reader changes [draws] in place and raises its version, which
  /// its runner follows.
  List<DrawPlan> withDraws(List<DrawPlan> draws) {
    final had = _all;
    if (had != null && identical(had._b, draws)) return had;
    return _all = _Joined(plans, draws);
  }

  _Joined? _all;

  /// Keeps the view of [had] when it is over the same plans, for a set that
  /// is made again for new culling values.
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

  /// The buffer of three uints from which the GPU reads the group counts
  /// (DispatchIndirect).
  final BufferRef? indirect;

  /// The state that a frame runner keeps with this dispatch, such as its GPU
  /// reads and writes. It belongs to the runner and not to the plan.
  Object? runnerState;
}

/// The source of a texture or texel buffer that a shader reads.
sealed class TextureRef {
  const TextureRef();
}

/// A texture file by stem (`textures/<stem>.json` and `.bin`), read through
/// an sRGB view when [srgb] is set.
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

  /// True when the shader reads through an sRGB view of an 8-bit RGBA
  /// target, which decodes the texels.
  final bool srgb;
}

/// The contents of a texel buffer with its format as a DXGI name. [bytes]
/// may be the block of a frame role (FrameRole), whose bytes the plan gives
/// for the frame (FramePlan.block).
class BufferTexture extends TextureRef {
  const BufferTexture(this.bytes, this.format);
  final Uint8List bytes;
  final String format;
}

/// A texture filled with one constant texel, for an input that a pass does
/// not have yet, or with [width] × [height] texels that the frame makes from
/// data row by row in [texel]. The property maps of a particle file are an
/// example. The format is a DXGI name.
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

  /// The size of an image from data, or null for one texel everywhere.
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

  /// The address modes of U, V and W, each `wrap`, `clamp`, `mirror` or
  /// `border`.
  final List<String> address;
  final int anisotropy;

  /// The name of a comparison function, such as `less` or `lessEqual`, or
  /// null.
  final String? compare;
  final double minLod, maxLod, lodBias;
  final String border;
}

/// A read-write resource that a compute shader binds, a `u#` or a raw or
/// structured buffer `RawT#` or `RawU#`.
sealed class StorageRef {
  const StorageRef();
}

/// A buffer that holds [bytes] for this dispatch only. It is an input filled
/// on the CPU or a written buffer whose result nothing in the plan reads.
/// [format] is the texel format of a storage texel buffer.
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

/// The bindings of a shader stage. Constant buffers are bound by block name,
/// textures by GLSL name, samplers by `s#` register and storage resources by
/// name.
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

  /// The state that a frame runner keeps with these resources, such as their
  /// bindings in the order of a shader. It belongs to the runner and not to
  /// the plan.
  Object? runnerState;
}

/// The blend state of one colour target.
class Blend {
  const Blend({
    this.enabled = false,
    this.color = const ['one', 'zero', 'add'],
    this.alpha = const ['one', 'zero', 'add'],
    this.writeMask = 0xf,
  });
  final bool enabled;

  /// The source factor, the destination factor and the operation.
  final List<String> color, alpha;
  final int writeMask;
}

/// The stencil test of a draw, the same for both faces. It compares the
/// reference of the draw with the stored value, both under [readMask]. It
/// applies the operation to the bits of [writeMask] where the stencil and
/// depth tests pass. A failing test keeps the stored value.
class Stencil {
  const Stencil({
    this.func = 'always',
    this.passOp = 'keep',
    this.readMask = 0xff,
    this.writeMask = 0xff,
  });

  /// The comparison, such as `always` or `equal`, in the terms of
  /// [DrawState.depthFunc].
  final String func;

  /// `keep` or `replace`.
  final String passOp;
  final int readMask, writeMask;
}

/// Raster and depth state of a draw.
///
/// [frontCounterClockwise] has the meaning of Direct3D 11. The winding is
/// counted on the render target, with y down. A triangle that is
/// counter-clockwise in clip space with y up, the front face of glTF and
/// OpenGL, is clockwise there, which the default `false` makes the front.
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

  /// The stencil test with [DrawPlan.stencilRef], or null when it is off.
  final Stencil? stencil;
}

/// The source of the vertices of a draw.
sealed class DrawGeometry {
  const DrawGeometry();
}

/// The shipped streams of a mesh in `meshes/<stem>.glb`, drawn with
/// [indexCount] indices of the index buffer [ibuffer] from [firstIndex].
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

  /// The buffer from which the GPU reads the index count, instance count,
  /// first index, base vertex and first instance
  /// (DrawIndexedInstancedIndirect). The index range above still selects the
  /// start of the bound index buffer.
  final BufferRef? indirect;

  /// The vertex inputs fed from frame buffers in place of the mesh, by input
  /// register, each with the buffer range, its stride and the DXGI format of
  /// the input. The skinned positions that a compute pass writes are an
  /// example.
  final Map<int, (BufferRef, int, String)> streams;
}

/// A draw of vertices given inline, such as the four-vertex screen quad of
/// a post pass. One vertex buffer holds vertices of [stride] bytes. Their
/// attributes are fed to the inputs of the vertex shader by register.
/// [registers] maps each input register to a DXGI format and a byte offset.
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

  /// The [vertexCount] U16 indices when the draw is indexed.
  final Uint8List? indices;
}

/// A full-screen draw of [vertexCount] vertices without buffers, for a pass
/// that builds its vertices from SV_VertexID.
class ScreenGeometry extends DrawGeometry {
  const ScreenGeometry(this.vertexCount, {this.instances = 1});
  final int vertexCount, instances;
}

/// One draw with its shaders as ids into the shader library, its geometry,
/// state, viewport and the resources of each stage.
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

  /// The x, y, width, height, min depth and max depth.
  final List<double> viewport;
  final StageResources vertexResources, pixelResources;
  final String label;
  final int stencilRef;

  /// The state that a frame runner keeps with this draw, such as its
  /// pipeline, vertex sources and the targets it reads. It belongs to the
  /// runner and not to the plan. A kept draw finds them without a lookup
  /// per frame.
  Object? runnerState;
}
