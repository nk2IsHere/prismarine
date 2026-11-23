#version 460 core
// A 4 by 4 filter of the half-size occlusion that covers its pattern, with
// weights that fall with the difference in depth.
precision highp float;
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s1;
#define depth_S s1
uniform texture2D aoRaw; // t1
#define aoRaw_S s1

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  vec2 full = cb2.view.xy;
  ivec2 hp = ivec2(gl_FragCoord.xy);
  ivec2 size = textureSize(sampler2D(aoRaw, s1), 0);
  float z = linearDepth(texelFetch(sampler2D(depth, s1), hp * 2, 0).r);
  float sum = 0.0, weights = 0.0;
  for (int y = -2; y < 2; y++) {
    for (int x = -2; x < 2; x++) {
      ivec2 q = clamp(hp + ivec2(x, y), ivec2(0), size - 1);
      float qz = linearDepth(texelFetch(sampler2D(depth, s1), q * 2, 0).r);
      float w = max(1.0 - abs(qz - z) / (0.05 * z + 0.02), 0.0) + 1e-3;
      sum += texelFetch(sampler2D(aoRaw, s1), q, 0).r * w;
      weights += w;
    }
  }
  color = vec4(sum / weights, 0.0, 0.0, 1.0);
}
