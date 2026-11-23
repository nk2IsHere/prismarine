#version 460 core
// Reflections from the screen. A surface smoother than the highest
// roughness marches its reflected ray through the depth buffer and refines a
// hit by bisection. A hit reads the light of the last frame at its place in
// the last frame, at a mip that grows with the roughness and the length of
// the ray. The weight in alpha falls at the edges of the screen and with the
// roughness.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s1;
#define depth_S s1
uniform texture2D gbufferNormal; // t1
#define gbufferNormal_S s1
uniform texture2D history; // t2
#define history_S s1

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

vec3 project(vec3 w) {
  vec4 c = cb0.viewProjection * vec4(w, 1.0);
  c.xyz /= c.w;
  return vec3(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5, c.z);
}

void main() {
  vec2 full = cb2.view.xy;
  ivec2 px = ivec2(uv * full);
  float z = texelFetch(sampler2D(depth, s1), px, 0).r;
  color = vec4(0.0);
  if (z >= 1.0) return;
  vec4 g = texelFetch(sampler2D(gbufferNormal, s1), px, 0);
  float roughness = g.z;
  if (roughness > cb2.ssrParams.y) return;
  vec3 n = octDecode(g.xy);
  vec3 p = worldAt(uv, z);
  vec3 v = normalize(cb0.camera.xyz - p);
  vec3 r = reflect(-v, n);
  float viewDepth = linearDepth(z);
  // A ray towards the camera leaves the depth buffer at once.
  float toward = dot(r, cb2.cameraForward.xyz);
  if (toward < -0.6) return;
  float reach = viewDepth * 2.0 + 2.0;
  vec3 from = p + n * (0.02 * viewDepth);
  vec3 a = project(from);
  vec3 b = project(from + r * reach);
  // Clip the end of the ray to the near plane side of the view.
  vec4 cb = cb0.viewProjection * vec4(from + r * reach, 1.0);
  if (cb.w < 0.05) {
    float k = (dot(cb2.cameraForward.xyz, from - cb0.camera.xyz) - 0.05) / max(-toward, 1e-4);
    b = project(from + r * min(reach, k));
  }
  int steps = int(cb2.ssrParams.x);
  ivec2 cell = ivec2(gl_FragCoord.xy) & 3;
  float jitter = float(cell.x * 4 + cell.y) / 16.0 + fract(cb2.ssrParams.w * 0.618034);
  jitter = fract(jitter);
  float thickness = cb2.ssrParams.z;
  float wa = 1.0 / linearDepth(a.z), wb = 1.0 / linearDepth(b.z);
  float lo = 0.0, hi = -1.0;
  for (int i = 1; i <= steps; i++) {
    float t = (float(i) - 1.0 + jitter) / float(steps);
    vec2 q = mix(a.xy, b.xy, t);
    if (any(lessThan(q, vec2(0.0))) || any(greaterThan(q, vec2(1.0)))) break;
    float rayDepth = 1.0 / mix(wa, wb, t);
    float sceneDepth = linearDepth(texelFetch(sampler2D(depth, s1), ivec2(q * full), 0).r);
    float behind = rayDepth - sceneDepth;
    if (behind > 0.0 && behind < thickness + 0.02 * rayDepth) {
      hi = t;
      break;
    }
    lo = t;
  }
  if (hi < 0.0) return;
  for (int i = 0; i < 4; i++) {
    float t = (lo + hi) * 0.5;
    vec2 q = mix(a.xy, b.xy, t);
    float rayDepth = 1.0 / mix(wa, wb, t);
    float sceneDepth = linearDepth(texelFetch(sampler2D(depth, s1), ivec2(q * full), 0).r);
    if (rayDepth > sceneDepth) {
      hi = t;
    } else {
      lo = t;
    }
  }
  vec2 q = mix(a.xy, b.xy, hi);
  float hz = texelFetch(sampler2D(depth, s1), ivec2(q * full), 0).r;
  vec3 hit = worldAt(q, hz);
  // The hit must face the ray.
  vec3 hn = octDecode(texelFetch(sampler2D(gbufferNormal, s1), ivec2(q * full), 0).xy);
  if (dot(hn, r) > 0.2) return;
  vec4 last = cb2.previousViewProjection * vec4(hit, 1.0);
  vec2 lastUv = vec2(last.x / last.w * 0.5 + 0.5, 0.5 - last.y / last.w * 0.5);
  if (any(lessThan(lastUv, vec2(0.0))) || any(greaterThan(lastUv, vec2(1.0)))) return;
  float spread = roughness * distance(hit, p) / max(viewDepth, 0.1) * full.y * 0.25;
  float lod = clamp(log2(max(spread, 1.0)), 0.0, 4.0);
  vec3 light = textureLod(sampler2D(history, s1), lastUv, lod).rgb;
  vec2 edge = smoothstep(vec2(0.0), vec2(0.08), lastUv) * smoothstep(vec2(0.0), vec2(0.08), 1.0 - lastUv);
  float fade = edge.x * edge.y * (1.0 - smoothstep(cb2.ssrParams.y * 0.6, cb2.ssrParams.y, roughness));
  fade *= 1.0 - smoothstep(0.8, 1.0, hi);
  color = vec4(light, fade);
}
