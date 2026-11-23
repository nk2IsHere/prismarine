// The constant blocks of the lit and shadow shaders. Draw holds the
// matrices and the material of one draw in the std140 layout that the
// builder writes.
#include "Pbr/bodies/frame_block.glsl"

uniform Draw {
  mat4 model;
  // The inverse transpose of the model matrix in its first three columns
  mat4 normalMatrix;
  vec4 baseColorFactor;
  // x metallic, y roughness, z alpha cutoff, w normal scale
  vec4 material;
  // rgb the emissive factor
  vec4 emissive;
} cb1;
