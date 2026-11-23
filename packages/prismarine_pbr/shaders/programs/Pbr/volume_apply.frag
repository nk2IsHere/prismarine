#version 460 core
precision highp float;
// The fog in front of each pixel from the summed froxels, added to the scene
// with the transmittance as the blend factor of the scene.
#include "Pbr/bodies/volume_block.glsl"

uniform texture2D depth; // t0
uniform sampler s0;
#define depth_S s0
uniform texture3D integrated; // t3
#define integrated_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  float d = texelFetch(sampler2D(depth, s0), ivec2(gl_FragCoord.xy), 0).r;
  float near = cb1.camera.w, far = cb1.right.w;
  float z = near / max(1.0 - d * (far - near) / far, 1e-6);
  float n = cb1.grid.z;
  // Interleaved gradient noise of Jimenez hides the steps between slices.
  float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float t = volumeSlice(min(z, cb1.depth.y)) + (noise - 0.5) / n;
  vec3 at = vec3(uv, clamp(t - 0.5 / n, 0.5 / n, 1.0 - 0.5 / n));
  vec4 v = texture(sampler3D(integrated, s0), at);
  // In front of the first slice the fog fades in with the depth.
  float near0 = clamp(z / volumeDepth(1.0 / n), 0.0, 1.0);
  color = vec4(v.rgb * near0, mix(1.0, v.a, near0));
}
