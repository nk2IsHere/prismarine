import 'row_layout.dart';

/// The row of one drawn object: the [members] of an application's object
/// block, which the shaders read as `Object.<member>`, then the fields that
/// the renderer fills. These are the object's light set, its flags and the
/// box around its meshes, which are culled as a whole.
RowLayout objectRowOf(List<RowField> members) =>
    RowLayout('ObjectRow', [...members, ...objectRowFields]);

/// The fields of [objectRowOf] that the renderer fills.
const objectRowFields = [
  RowField('lightSet', FieldType.uint),
  RowField('flags', FieldType.uint),
  RowField('boundsMin', FieldType.vec3),
  RowField('boundsMax', FieldType.vec3),
];

/// Object flags ([objectRowOf] `flags`).
abstract final class ObjectFlags {
  /// Never culled.
  static const noCull = 1 << 0;

  /// Deformable (skinned): its batches skip the batch-sphere test.
  static const deformable = 1 << 1;

  /// Shown this frame (visible itself and its scene shown).
  static const visible = 1 << 2;

  /// Casts shadows.
  static const castsShadow = 1 << 3;
}

/// The row of one mesh batch of an object: the [members] of an
/// application's instance block, which the shaders read as
/// `Instance.<member>`, then the fields that the renderer fills. These are
/// the object's row, the material's words, the pipeline bucket, the place of
/// the batch's triangles in its cooked pool, its skinning output and its
/// bounding sphere.
RowLayout instanceRowOf(List<RowField> members) =>
    RowLayout('InstanceRow', [...members, ...instanceRowFields]);

/// The fields of [instanceRowOf] that the renderer fills.
const instanceRowFields = [
  RowField('object', FieldType.uint),
  // Word offsets in the material table: the material's two blocks and the
  // array layers of its texture inputs.
  RowField('materialBase', FieldType.uint),
  RowField('materialMain', FieldType.uint),
  RowField('materialTextures', FieldType.uint),
  RowField('bucket', FieldType.uint),
  RowField('flags', FieldType.uint),
  RowField('firstIndex', FieldType.uint),
  RowField('indexCount', FieldType.uint),
  RowField('baseVertex', FieldType.uint),
  RowField('skinOutput', FieldType.uint),
  RowField('sphere', FieldType.vec4),
];

/// Instance flags ([instanceRowOf] `flags`): which pass kinds draw it.
abstract final class InstanceFlags {
  static const gBuffer = 1 << 0;
  static const main = 1 << 1;
  static const shadow = 1 << 2;

  /// Alpha-blended: drawn in its own sorted run, not a bucket's.
  static const blended = 1 << 3;
}
