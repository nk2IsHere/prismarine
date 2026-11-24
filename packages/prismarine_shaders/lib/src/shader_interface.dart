/// Returns the interface of the GLSL [source] of a shader of [stage] in the
/// JSON form that `ShaderRecord` of prismarine_frame reads. [stage] is
/// `vertex`, `pixel` or `compute`.
///
/// The interface comes from the declarations, which follow these rules.
///
/// | Part | Declaration |
/// |---|---|
/// | Uniform block | `uniform Frame { … } cb0;`, its slot after `cb`. Its rows are its std140 size in 16-byte rows. A block that the code does not read, such as one from a shared include, is left out. |
/// | Texture | `uniform texture2D baseColor; // t0`, its slot in the comment. |
/// | Sampler | `uniform sampler s0;`, or `uniform samplerShadow s4;` for a comparison sampler. |
/// | Texture and sampler pair | `#define baseColor_S s0` |
/// | Vertex input | `layout(location = 0) in vec3 vsi0_POSITION0;`, its register, semantic and index in the name. |
/// | Storage | `uniform image2D name;`, with or without access qualifiers such as `writeonly`, or `buffer RawName { … }`, `readonly` for one that the stage only reads. |
Map<String, Object?> shaderInterface(String source, String stage) {
  final blocks = [
    for (final m in RegExp(
      r'uniform (\w+)\s*\{([^}]*)\}\s*(\w+);',
    ).allMatches(source))
      // A block that the code does not read is compiled out and has no
      // binding. The runner must not bind bytes to it.
      if (RegExp('\\b${m[3]}\\.').hasMatch(source))
        {
          'name': m[1],
          'parameter': null,
          'slot': int.tryParse(m[3]!.replaceFirst('cb', '')) ?? 0,
          'rows': std140Rows(m[2]!),
        },
  ];
  final textures = [
    for (final m in RegExp(
      r'uniform (\w*texture\w*) (\w+);(?:\s*// t(\d+))?',
    ).allMatches(source))
      {
        'name': m[2],
        'type': m[1],
        'parameter': null,
        'slot': int.tryParse(m[3] ?? '') ?? 0,
      },
  ];
  final samplers = [
    for (final m in RegExp(
      r'uniform sampler(Shadow)? s(\d+);',
    ).allMatches(source))
      {
        'name': 's${m[2]}',
        'slot': int.parse(m[2]!),
        'comparison': m[1] != null,
      },
  ];
  final pairs = {
    for (final m in RegExp(r'#define (\w+)_S s(\d+)').allMatches(source))
      m[1]!: int.parse(m[2]!),
  };
  final attributes = [
    for (final m in RegExp(
      r'layout\(location = (\d+)\) in (\w+) vsi(\d+)_([A-Z]+?)(\d+);',
    ).allMatches(source))
      {
        'location': int.parse(m[1]!),
        'register': int.parse(m[3]!),
        'semantic': m[4],
        'index': int.parse(m[5]!),
        'type': m[2],
        'name': 'vsi${m[3]}_${m[4]}${m[5]}',
      },
  ];
  final storage = <String, String>{
    for (final m in RegExp(
      r'uniform (?:(?:writeonly|readonly|coherent|restrict) )*(\w*image\w*) (\w+);',
    ).allMatches(source))
      m[2]!: m[1]!,
    for (final m in RegExp(r'buffer (Raw\w+)\s*\{').allMatches(source))
      m[1]!: 'buffer',
  };
  final readonly = [
    for (final m in RegExp(r'readonly buffer (Raw\w+)\s*\{').allMatches(source))
      m[1]!,
  ];
  return {
    'stage': stage,
    'blocks': blocks,
    'textures': textures,
    'samplers': samplers,
    if (attributes.isNotEmpty) 'attributes': attributes,
    if (storage.isNotEmpty) 'storage': storage,
    if (readonly.isNotEmpty) 'readonly': readonly,
    'bindings': [
      for (final t in textures)
        {'name': t['name'], 'size': 0, 'sampler': ?pairs[t['name']]},
    ],
  };
}

/// Returns the 16-byte rows of a uniform block with [members] in the std140
/// layout. A scalar takes 4 bytes, a vec2 8, a vec3 and a vec4 16. A matrix
/// takes a row per column. The elements of an array are 16 bytes apart. A
/// precision qualifier before a type is skipped.
int std140Rows(String members) {
  var at = 0;
  for (final m in RegExp(
    r'(\w+)\s+\w+(?:\[(\d+)\])?\s*;',
  ).allMatches(members)) {
    final type = m[1]!;
    final n = int.tryParse(m[2] ?? '');
    final width = switch (type) {
      'float' || 'int' || 'uint' || 'bool' => 4,
      'vec2' || 'ivec2' || 'uvec2' => 8,
      'vec3' || 'ivec3' || 'uvec3' => 12,
      _ => 16,
    };
    final columns = switch (type) {
      'mat4' || 'mat2x4' || 'mat3x4' || 'mat4x4' => 4,
      'mat3' || 'mat3x3' || 'mat4x3' => 3,
      'mat2' || 'mat2x2' => 2,
      _ => 1,
    };
    final align = n != null || width > 8 ? 16 : width;
    at = (at + align - 1) ~/ align * align;
    at += n != null ? 16 * columns * n : (columns > 1 ? 16 * columns : width);
  }
  return (at + 15) ~/ 16;
}
