// The frame block of every lit and shadow shader, with the view and the
// lights of the frame in the std140 layout that the builder writes.
uniform Frame {
  mat4 viewProjection;
  mat4 shadowMatrix;
  // xyz the camera position, w the exposure
  vec4 camera;
  // xyz the direction towards the sun, w 1 with shadows
  vec4 sunDirection;
  // rgb the colour times the intensity
  vec4 sunColor;
  vec4 skyColor;
  // rgb the ambient colour from below, w the count of point lights
  vec4 groundColor;
  // x the texel size of the shadow map, y the depth bias, z the normal offset
  vec4 shadowParams;
  // xyz the position, w the range, 0 for none
  vec4 lightPosition[16];
  // rgb the colour times the intensity
  vec4 lightColor[16];
  // x and y the scale of the projection, z the radius of a light's marker,
  // w 1 with markers
  vec4 markers;
} cb0;
