import 'row_layout.dart';

/// Returns the row of one drawn object. It holds the [members] of the object
/// block of an application, which the shaders read as `Object.<member>`,
/// then the fields that the renderer fills. These are the light set of the
/// object, its flags and the box around its meshes, which are culled as a
/// whole.
RowLayout objectRowOf(List<RowField> members) =>
    RowLayout('ObjectRow', [...members, ...objectRowFields]);

/// The fields of [objectRowOf] that the renderer fills.
const objectRowFields = [
  RowField('lightSet', FieldType.uint),
  RowField('flags', FieldType.uint),
  RowField('boundsMin', FieldType.vec3),
  RowField('boundsMax', FieldType.vec3),
];

/// The flags of an object, the `flags` field of [objectRowOf].
abstract final class ObjectFlags {
  /// The object is not culled.
  static const noCull = 1 << 0;

  /// The object is deformable, such as a skinned object. Its batches skip
  /// the batch-sphere test.
  static const deformable = 1 << 1;

  /// The object is shown this frame. It is visible and its scene is shown.
  static const visible = 1 << 2;

  /// The object casts shadows.
  static const castsShadow = 1 << 3;
}

/// Returns the row of one mesh batch of an object. It holds the [members] of
/// the instance block of an application, which the shaders read as
/// `Instance.<member>`, then the fields that the renderer fills. These are
/// the row of the object, the words of the material, the pipeline bucket,
/// the place of the triangles of the batch in its cooked pool, its skinning
/// output and its bounding sphere.
RowLayout instanceRowOf(List<RowField> members) =>
    RowLayout('InstanceRow', [...members, ...instanceRowFields]);

/// The fields of [instanceRowOf] that the renderer fills.
const instanceRowFields = [
  RowField('object', FieldType.uint),
  // Word offsets in the material table of the two blocks of the material and
  // the array layers of its texture inputs.
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

/// The flags of an instance, the `flags` field of [instanceRowOf], with the
/// pass kinds that draw it.
abstract final class InstanceFlags {
  static const gBuffer = 1 << 0;
  static const main = 1 << 1;
  static const shadow = 1 << 2;

  /// The instance is alpha-blended and drawn in its own sorted run, not in
  /// the run of a bucket.
  static const blended = 1 << 3;
}
