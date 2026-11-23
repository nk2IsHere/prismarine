/// A constant buffer a shader declares: its uniform block name, the id of
/// its parameter, its `cb#` register and its size in 16-byte rows.
class ShaderBlock {
  ShaderBlock(this.name, this.parameter, this.slot, this.rows);
  final String name;

  /// The id of the parameter that the block holds. Null for a block of the
  /// renderer's own shaders, such as the stencil copy's.
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

/// The interface of one shader and the place of its entry in a shader
/// library. It reads the JSON form of a shader's reflection and the JSON of
/// its build.
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

  /// A vertex stage that clamps depth per vertex and leaves the clamp per
  /// pixel to a depth-clamp pixel shader, as Direct3D's depth clamp does.
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

  /// The entry in its shader library and the library, when it was built
  /// into one.
  String? get entry =>
      build?['state'] == 'bundled' ? build!['entry'] as String : null;
  String? get shard =>
      build?['state'] == 'bundled' ? build!['shard'] as String : null;
}
