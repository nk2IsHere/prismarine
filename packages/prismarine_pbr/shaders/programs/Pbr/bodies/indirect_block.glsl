// The block of the indirect light in the std140 layout that the builder
// writes each frame, with the helpers that read it.
uniform Indirect {
  mat4 inverseViewProjection;
  mat4 previousViewProjection;
  // x and y the size of the view in pixels, z and w their inverses
  vec4 view;
  // 1 for each effect that is on, x the sky, y the probes, z the occlusion
  // and w the reflections
  vec4 switches;
  // xyz the place of the first probe, w the spacing of the probes
  vec4 probeOrigin;
  // xyz the probe counts, w the tiles per row of the atlases
  vec4 probeCounts;
  // xy the texel size of the irradiance atlas, zw the one of the distance
  // atlas
  vec4 atlas;
  // x the first probe of this frame in the list, y the probes of this
  // frame, z the probes in the list, w the rays per probe
  vec4 trace;
  // The rows of the rotation of this frame's rays
  vec4 rayRotation[3];
  // xyz the corner of the voxel grid, w the side of a cell
  vec4 voxelOrigin;
  // xyz the cell counts, w the longest distance that a probe records
  vec4 voxelCounts;
  // x the factor of the sky's radiance, y the factor of the indirect light,
  // z the last mip of the specular sky, w the last mip of the sky
  vec4 skyParams;
  // x the hysteresis, y the bounce factor, z the normal bias and w the view
  // bias of a probe read, both in shares of the spacing
  vec4 probeParams;
  // x the radius, y the strength, z the directions, w the steps
  vec4 aoParams;
  // x the steps, y the highest roughness, z the thickness, w the frame
  vec4 ssrParams;
  // x the debug view, y and z the depth terms of the projection, w its y
  // scale
  vec4 misc;
  // xyz the forward axis of the camera
  vec4 cameraForward;
} cb2;

#include "Pbr/bodies/gi_common.glsl"

// The distance along the view of a depth from the depth buffer.
float linearDepth(float z) {
  return cb2.misc.z / (z + cb2.misc.y);
}

// The world position of the depth z at the texture coordinates uv of the
// view.
vec3 worldAt(vec2 uv, float z) {
  vec4 w = cb2.inverseViewProjection * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, z, 1.0);
  return w.xyz / w.w;
}

mat3 rayRotation() {
  return transpose(mat3(cb2.rayRotation[0].xyz, cb2.rayRotation[1].xyz, cb2.rayRotation[2].xyz));
}
