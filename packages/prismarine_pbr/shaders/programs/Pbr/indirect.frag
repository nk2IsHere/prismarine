#version 460 core
// The indirect light of the opaque surfaces, added to the direct light. It
// reads their normal, roughness, metallic value and base colour, the
// occlusion and the reflections. A debug view replaces the frame with one
// term.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s5;
#define depth_S s5
uniform texture2D gbufferNormal; // t1
#define gbufferNormal_S s5
uniform texture2D gbufferAlbedo; // t2
#define gbufferAlbedo_S s5
uniform texture2D ao; // t3
#define ao_S s5
uniform texture2D ssr; // t4
#define ssr_S s5
uniform texture2D giDiffuseHalf; // t5
#define giDiffuseHalf_S s5
uniform texture2D giSpecularHalf; // t6
#define giSpecularHalf_S s5
uniform texture2D brdfLut; // t7
#define brdfLut_S s5

#include "Pbr/bodies/indirect_compose.glsl"

// The half-size irradiance and reflected radiance at full-size pixel px of
// depth z, from the four nearest half-size texels weighed by their depth.
void upsample(ivec2 px, float z, out vec3 irradiance, out vec3 env) {
  ivec2 size = textureSize(sampler2D(giDiffuseHalf, s5), 0);
  vec2 f = (vec2(px) + 0.5) * 0.5 - 0.5;
  ivec2 i0 = ivec2(floor(f));
  vec2 t = f - vec2(i0);
  float d = linearDepth(z);
  irradiance = vec3(0.0);
  env = vec3(0.0);
  float total = 0.0;
  for (int k = 0; k < 4; k++) {
    ivec2 o = ivec2(k & 1, k >> 1);
    ivec2 q = clamp(i0 + o, ivec2(0), size - 1);
    float qd = linearDepth(texelFetch(sampler2D(depth, s5), q * 2 + 1, 0).r);
    vec2 b = mix(1.0 - t, t, vec2(o));
    float w = b.x * b.y * (max(1.0 - abs(qd - d) / (0.05 * d + 0.02), 0.0) + 1e-3);
    irradiance += texelFetch(sampler2D(giDiffuseHalf, s5), q, 0).rgb * w;
    env += texelFetch(sampler2D(giSpecularHalf, s5), q, 0).rgb * w;
    total += w;
  }
  irradiance /= total;
  env /= total;
}

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  ivec2 px = ivec2(gl_FragCoord.xy);
  float z = texelFetch(sampler2D(depth, s5), px, 0).r;
  int view = int(cb2.misc.x);
  if (z >= 1.0) {
    color = vec4(0.0);
    if (view == 0) discard;
    return;
  }
  vec4 g = texelFetch(sampler2D(gbufferNormal, s5), px, 0);
  vec3 base = texelFetch(sampler2D(gbufferAlbedo, s5), px, 0).rgb;
  vec3 n = octDecode(g.xy);
  vec3 p = worldAt(uv, z);
  vec3 v = normalize(cb0.camera.xyz - p);
  vec3 irradiance, env;
  upsample(px, z, irradiance, env);
  float occlusion = cb2.switches.z > 0.5 ? textureLod(sampler2D(ao, s5), uv, 0.0).r : 1.0;
  vec4 reflection = cb2.switches.w > 0.5 ? textureLod(sampler2D(ssr, s5), uv, 0.0) : vec4(0.0);
  vec3 diffuse, specular;
  if (view == 1) {
    composeIndirect(n, v, vec3(1.0), 0.0, 1.0, occlusion, vec4(0.0), irradiance, env, diffuse, specular);
    color = vec4(diffuse, 1.0);
  } else if (view == 2) {
    color = vec4(vec3(occlusion), 1.0);
  } else if (view == 3) {
    composeIndirect(n, v, vec3(1.0), 1.0, g.z, occlusion, reflection, irradiance, env, diffuse, specular);
    color = vec4(specular, 1.0);
  } else {
    composeIndirect(n, v, base, g.w, g.z, occlusion, reflection, irradiance, env, diffuse, specular);
    color = vec4(diffuse + specular, 0.0);
  }
}
