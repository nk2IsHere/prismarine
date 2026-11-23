#version 460 core
// Ambient occlusion at half size from the depth and the normals, by the
// scalable estimate of McGuire, Mara and Luebke: samples on a spiral in a
// disc of the radius in world units, each weighed by its angle to the
// normal and its distance. The spiral turns by a 4 by 4 pattern and the
// frame.
precision highp float;
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s1;
#define depth_S s1
uniform texture2D gbufferNormal; // t1
#define gbufferNormal_S s1

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  vec2 full = cb2.view.xy;
  ivec2 px = ivec2(uv * full);
  float z = texelFetch(sampler2D(depth, s1), px, 0).r;
  if (z >= 1.0) {
    color = vec4(1.0);
    return;
  }
  vec3 p = worldAt(uv, z);
  vec3 n = octDecode(texelFetch(sampler2D(gbufferNormal, s1), px, 0).xy);
  float radius = cb2.aoParams.x;
  float viewDepth = linearDepth(z);
  float pixels = radius * cb2.misc.w * full.y * 0.5 / viewDepth;
  if (pixels < 1.0) {
    color = vec4(1.0);
    return;
  }
  pixels = min(pixels, 0.25 * full.y);
  int samples = int(cb2.aoParams.z * cb2.aoParams.w);
  ivec2 cellOf = ivec2(gl_FragCoord.xy) & 3;
  float pattern = float(cellOf.x * 4 + cellOf.y) / 16.0;
  float angle = (pattern + fract(cb2.ssrParams.w * 0.618034)) * 2.0 * PI;
  float r2 = radius * radius;
  float sum = 0.0;
  for (int i = 0; i < samples; i++) {
    float a = (float(i) + 0.5) / float(samples);
    float turn = a * 7.0 * 2.0 * PI + angle;
    vec2 offset = vec2(cos(turn), sin(turn)) * a * pixels;
    vec2 q = uv + offset / full;
    if (any(lessThan(q, vec2(0.0))) || any(greaterThan(q, vec2(1.0)))) continue;
    float qz = texelFetch(sampler2D(depth, s1), ivec2(q * full), 0).r;
    vec3 s = worldAt(q, qz) - p;
    float vv = dot(s, s);
    float vn = dot(s, n);
    float f = max(r2 - vv, 0.0);
    sum += f * f * f * max((vn - 0.01 * viewDepth) / (vv + 0.01), 0.0);
  }
  float occlusion = max(0.0, 1.0 - sum * cb2.aoParams.y * 5.0 / (r2 * r2 * r2 * float(samples)));
  color = vec4(occlusion, 0.0, 0.0, 1.0);
}
