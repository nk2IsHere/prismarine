// The block of the froxel grid of the volumetric light. Slice k of n starts
// at the depth near * (far / near) ^ (k / n) along the view.
uniform Volume {
  mat4 previousViewProjection;
  // xyz the camera position, w the near plane of the camera
  vec4 camera;
  // xyz the right axis times the tangent of half the horizontal field of
  // view, w the far plane of the camera
  vec4 right;
  // xyz the up axis times the tangent of half the vertical field of view
  vec4 up;
  // xyz the view direction
  vec4 forward;
  vec4 previousCamera;
  vec4 previousForward;
  // xyz the froxels along x, y and depth, w the depth offset of this frame
  vec4 grid;
  // x the near end, y the far end, z the log of far over near, w the share
  // of the last frame
  vec4 depth;
  // x the extinction per metre, y its falloff per metre of height, z the
  // height of the full density, w the anisotropy
  vec4 fog;
  // x the sun, y the point lights, z the ambient light
  vec4 lights;
} cb1;

// The view depth of slice coordinate t from 0 to 1.
float volumeDepth(float t) {
  return cb1.depth.x * exp(t * cb1.depth.z);
}

// The slice coordinate from 0 to 1 of the view depth z.
float volumeSlice(float z) {
  return log(max(z, 1e-4) / cb1.depth.x) / cb1.depth.z;
}
