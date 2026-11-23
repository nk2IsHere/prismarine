#version 460 core
// A 4 by 4 filter of the reflections that covers the pattern of their
// rays. Each sample counts by its weight and by its depth against the
// centre's.
precision highp float;
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s5;
#define depth_S s5
uniform texture2D ssrRaw; // t1
#define ssrRaw_S s5

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  ivec2 size = textureSize(sampler2D(ssrRaw, s5), 0);
  ivec2 at = ivec2(gl_FragCoord.xy);
  ivec2 scale = ivec2(cb2.view.xy) / size;
  float z = linearDepth(texelFetch(sampler2D(depth, s5), at * scale, 0).r);
  vec3 light = vec3(0.0);
  float hits = 0.0, weights = 0.0;
  for (int y = -2; y < 2; y++) {
    for (int x = -2; x < 2; x++) {
      ivec2 q = clamp(at + ivec2(x, y), ivec2(0), size - 1);
      float qz = linearDepth(texelFetch(sampler2D(depth, s5), q * scale, 0).r);
      float w = max(1.0 - abs(qz - z) / (0.05 * z + 0.02), 0.0) + 1e-3;
      vec4 s = texelFetch(sampler2D(ssrRaw, s5), q, 0);
      light += s.rgb * s.a * w;
      hits += s.a * w;
      weights += w;
    }
  }
  color = vec4(hits > 0.0 ? light / hits : vec3(0.0), hits / weights);
}
