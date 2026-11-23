/// A constant buffer a shader declares: its uniform block name (the exe's
/// parameter name), parameter id, `cb#` register and size in 16-byte rows.
class ShaderBlock {
  ShaderBlock(this.name, this.parameter, this.slot, this.rows);
  final String name;

  /// The exe's parameter id; null for a block of the renderer's own shaders
  /// (the slice's stencil copy).
  final int? parameter;
  final int slot, rows;
}

/// A texture object (or texel buffer) a shader declares.
class TextureSlot {
  TextureSlot(this.name, this.type, this.parameter, this.slot);
  final String name, type;
  final int? parameter;
  final int slot;
}

/// A vertex input: GLSL location, semantic name and index.
class Attribute {
  Attribute(
    this.location,
    this.semantic,
    this.index,
    this.type,
    this.register, {
    String? glslName,
  }) : name = glslName ?? 'vsi$register';
  final int location, index, register;
  final String semantic, type;

  /// Its GLSL name: `vsi<register>`, or with its semantic in a native shader.
  final String name;
}

/// One translated shader and where its bundle entry is.
class ShaderRecord {
  ShaderRecord(this.json, this.build)
    : stage = json['stage'] as String,
      blocks = [
        for (final b in (json['blocks'] as List? ?? const []).cast<Map>())
          // A block compiled out has no binding to fill.
          if ((build?['bound'] as List?)?.contains(b['name']) ?? true)
            ShaderBlock(
              b['name'] as String,
              b['parameter'] as int?,
              b['slot'] as int,
              b['rows'] as int,
            ),
      ],
      textures = [
        for (final t in (json['textures'] as List? ?? const []).cast<Map>())
          TextureSlot(
            t['name'] as String,
            t['type'] as String,
            t['parameter'] as int?,
            t['slot'] as int,
          ),
      ],
      samplers = [
        for (final s in (json['samplers'] as List? ?? const []).cast<Map>())
          (s['slot'] as int, s['comparison'] as bool),
      ],
      attributes = [
        for (final a in (json['attributes'] as List? ?? const []).cast<Map>())
          Attribute(
            a['location'] as int,
            a['semantic'] as String,
            a['index'] as int,
            a['type'] as String,
            a['register'] as int,
            glslName: a['name'] as String?,
          ),
      ];
  final Map<String, Object?> json;
  final Map<String, Object?>? build;
  final String stage;
  final List<ShaderBlock> blocks;
  final List<TextureSlot> textures;

  /// (`s#` register, comparison) per sampler object.
  final List<(int, bool)> samplers;
  final List<Attribute> attributes;

  /// A vertex stage that clamps depth per vertex and leaves the per-pixel
  /// clamp to the slice's depth-clamp pixel shader (Direct3D's depth clamp,
  /// the key light's cascades).
  bool get depthClamp => json['depthClamp'] == true;

  /// Storage resources by name → `buffer` or the image type (`image2D`,
  /// `image2DArray`, `uimage3D`, `imageBuffer`, …).
  late final Map<String, String> storage = {
    for (final MapEntry(:key, :value)
        in ((json['storage'] as Map?) ?? const {}).entries)
      key as String: value as String,
  };

  /// The storage buffers it only reads (`readonly buffer`).
  late final Set<String> readonlyStorage = {
    for (final n in (json['readonly'] as List?) ?? const []) n as String,
  };

  /// The bundle entry (`g<hash>`) and shard, when it bundled.
  String? get entry =>
      build?['state'] == 'bundled' ? build!['entry'] as String : null;
  String? get shard =>
      build?['state'] == 'bundled' ? build!['shard'] as String : null;
}
