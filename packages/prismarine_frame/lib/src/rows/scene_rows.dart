import 'row_layout.dart';

/// One per drawn agent. Its first members are S2's BufferObject member for
/// member (effects/buffers.glsl; formats/s2/shaders.md "BufferObject"), so
/// the effects' pulled form reads `Object.<member>` from this row unchanged;
/// the renderer's own fields follow: the agent's light set, its flags and
/// its render object's union box (formats/s2/frame.md "Which batches draw":
/// the exe culls an agent's render object as a whole).
final objectRow = RowLayout('ObjectRow', const [
  RowField('sWorldMatrix', FieldType.rows3x4),
  RowField('sPrevWorldMatrix', FieldType.rows3x4),
  RowField('sObjectAlpha', FieldType.float),
  RowField('sObjectMaterialTime', FieldType.float),
  RowField('sRecieveShadowsIntensity', FieldType.float),
  RowField('sRecieveShadowsDoublesided', FieldType.float),
  RowField('sObjectBrushNearDetailBias', FieldType.float),
  RowField('sObjectBrushFarDetailBias', FieldType.float),
  RowField('sObjectBrushScale', FieldType.float),
  RowField('sObjectBrushScaleByVertex', FieldType.float),
  RowField('sObjectDiffuseColor', FieldType.vec3),
  RowField('sObjectRimBumpDepth', FieldType.float),
  RowField('sObjectReflectionColor', FieldType.vec3),
  RowField('sObjectReflectionMipCount', FieldType.float),
  RowField('sEnlightenUVTransform', FieldType.vec4),
  RowField('sReflectionMatrix0', FieldType.vec3),
  RowField('sReflectionIntensityShadow', FieldType.float),
  RowField('sReflectionMatrix1', FieldType.vec3),
  RowField('sReflectionMatrix2', FieldType.vec3),
  RowField('pad0', FieldType.float),
  RowField('sStencilRef', FieldType.sint),
  RowField('sStencilMask', FieldType.sint),
  // The renderer's own.
  RowField('lightSet', FieldType.uint),
  RowField('flags', FieldType.uint),
  RowField('boundsMin', FieldType.vec3),
  RowField('boundsMax', FieldType.vec3),
]);

/// Object flags ([objectRow] `flags`).
abstract final class ObjectFlags {
  /// `Render Cull` off: never culled (formats/s2/frame.md).
  static const noCull = 1 << 0;

  /// Deformable (skinned): its batches skip the batch-sphere test.
  static const deformable = 1 << 1;

  /// Shown this frame (`Runtime: Visible` and its scene shown).
  static const visible = 1 << 2;

  /// Casts shadows.
  static const castsShadow = 1 << 3;
}

/// One per (agent, mesh batch). Its first members are S2's BufferInstance
/// member for member (effects/buffers.glsl), read as `Instance.<member>` by
/// the pulled effects; the position decode members stay at identity, as
/// the cooked pools hold the editable form's float positions. The
/// renderer's own fields follow: the object row, the material's words, the
/// pipeline bucket, where the batch's triangles are in its cooked pool, its
/// skinning output and its bounding sphere.
final instanceRow = RowLayout('InstanceRow', const [
  RowField('sLightmapTransform', FieldType.vec4),
  RowField('sTexCoordTransform0', FieldType.vec4),
  RowField('sTexCoordTransform1', FieldType.vec4),
  RowField('sTexCoordTransform2', FieldType.vec4),
  RowField('sTexCoordTransform3', FieldType.vec4),
  RowField('sMeshPositionScale', FieldType.vec3),
  RowField('sBatchLightmapIntensity', FieldType.float),
  RowField('sMeshPositionOffset', FieldType.vec3),
  RowField('sAlphaRef', FieldType.float),
  RowField('sMeshPositionWScale', FieldType.vec3),
  RowField('sLightmapPageIndex', FieldType.float),
  // The renderer's own.
  RowField('object', FieldType.uint),
  // Word offsets in the material table: the material's BufferMaterialBase
  // and BufferMaterialMain blocks and its texture inputs' array layers.
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
]);

/// Instance flags ([instanceRow] `flags`): which pass kinds draw it.
abstract final class InstanceFlags {
  static const gBuffer = 1 << 0;
  static const main = 1 << 1;
  static const shadow = 1 << 2;

  /// Alpha-blended: drawn in its own sorted run, not a bucket's.
  static const blended = 1 << 3;
}
