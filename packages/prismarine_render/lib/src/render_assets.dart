import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_frame/prismarine_frame.dart' show ShaderRecord;

import 'load_tally.dart';

/// The ids of the shaders that a frame runner uses besides the plan's own.
class RunnerShaders {
  const RunnerShaders({
    required this.nullPixel,
    required this.depthClampPixel,
    required this.stencilCopyVertex,
    required this.stencilCopyPixel,
  });

  /// An empty pixel shader, for the draws of a plan without a pixel shader.
  final String nullPixel;

  /// The pixel shader for the depth-only draws of a vertex stage that
  /// clamps depth. It clamps depth per pixel. Without it such draws use
  /// [nullPixel].
  final String depthClampPixel;

  /// The shaders that copy a stencil into a texture, one draw per value.
  /// Without them a read of a stencil gets a stand-in texture.
  final String stencilCopyVertex, stencilCopyPixel;
}

/// A load slower than this many ms goes to [RenderAssets.onSlow].
const slowLoadMs = 4.0;

/// The files that a frame runner uses: shaders by id, textures by stem and
/// mesh streams by stem, loaded on first use and kept until a release. The
/// runner asks for each one by the name that a frame plan gives.
abstract interface class RenderAssets {
  /// Returns true when shader [id] exists.
  bool hasShader(String id);

  /// Shader [id]'s interface: its blocks, textures, samplers and inputs.
  /// Null when there is no such shader.
  ShaderRecord? shaderRecord(String id);

  /// Loads the shader libraries that hold [ids].
  Future<void> loadShaders(Iterable<String> ids);

  /// Shader [id], its library loaded by [loadShaders].
  gpu.Shader shader(String id);

  /// Loads the textures among [stems] that [texture] cannot read on demand.
  Future<void> loadTextures(Iterable<String> stems);

  /// Returns true when texture [stem] exists.
  bool hasTexture(String stem);

  /// Texture [stem] with every mip and layer, through an sRGB view when
  /// [srgb] is set.
  gpu.Texture texture(String stem, {bool srgb = false});

  /// Mesh [stem]'s vertex and index buffers.
  RenderMesh mesh(String stem);

  /// The vertex inputs that the compiled stage of each shader lacks, by
  /// shader id.
  Map<String, Set<String>> get droppedInputs;

  /// Records input [name] as missing from shader [shaderId]. Returns false
  /// when it was known.
  bool dropInput(String shaderId, String name);

  /// The assets of directory [dir], with the same shaders.
  RenderAssets atDirectory(String dir);

  /// CPU time spent on loads so far, in ms.
  double get loadMs;

  /// The current phase of the loads: `record`, `prepare` or `warm`.
  String get phase;
  set phase(String p);

  /// Every load and pipeline made, counted by kind and phase.
  LoadTally get tally;

  /// Receives each load slower than a few ms: what, its ms, its bytes and
  /// the [phase].
  void Function(String what, double ms, int bytes, String phase)? get onSlow;

  /// The scene of the draws that are made ready now. Its loads can be
  /// forgotten while no other scene uses them.
  String? get tag;
  set tag(String? t);

  /// The open scene whose draws a warm-up makes ready. Its loads are that
  /// scene's too.
  set warmFor(String? scene);

  /// The scenes that ask for loads now, a bit each.
  set owners(int m);

  /// Receives the owners whenever they change.
  set onOwners(void Function(int owners)? f);

  /// A scene closed. Returns the epoch to give [release].
  int closed();

  /// Lets go of what nothing asked for since the close that returned
  /// [since], keeping what a scene in [keepOwners] asked for and the loads
  /// of the [held] scene. Returns how many were let go.
  int release(int since, {String? held, int keepOwners = 0});

  /// A line on what is held, for the memory census.
  String get census;
}

/// A mesh's buffers on the GPU and the vertex layouts that its draws need.
abstract interface class RenderMesh {
  List<gpu.DeviceBuffer> get indexBuffers;

  /// The layout that feeds the inputs of shader [shaderId] with interface
  /// [shader] from this mesh, and the buffer of each layout slot. Inputs
  /// whose register is in [skip] come from other buffers.
  (gpu.VertexLayout, List<gpu.DeviceBuffer>) layoutFor(
    String shaderId,
    ShaderRecord shader, {
    Iterable<int> skip = const [],
  });
}
