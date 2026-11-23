#version 460 core
// The irradiance and the reflected radiance of the probes and the sky at
// half size, for the indirect pass to scale up.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s5;
#define depth_S s5
#include "Pbr/bodies/depth_normal.glsl"
uniform texture2D gbufferNormal; // t1
#define gbufferNormal_S s5
uniform texture2D giIrradiance; // t2
#define giIrradiance_S s5
uniform texture2D giDistance; // t3
#define giDistance_S s5
uniform textureBuffer giProbes; // t4
uniform texture2D skyEnv; // t5
uniform sampler s6;
#define skyEnv_S s6
uniform texture2D skySpecular; // t6
#define skySpecular_S s6
uniform texture2D skyIrradiance; // t7
#define skyIrradiance_S s6
uniform texture2D brdfLut; // t8
#define brdfLut_S s5

#include "Pbr/bodies/gi_probes.glsl"
#include "Pbr/bodies/sky_read.glsl"
#include "Pbr/bodies/indirect_light.glsl"

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 irradiance;
layout(location = 1) out vec4 environment;

void main() {
  vec2 full = cb2.view.xy;
  ivec2 px = ivec2(uv * full);
  float z = texelFetch(sampler2D(depth, s5), px, 0).r;
  irradiance = vec4(0.0);
  environment = vec4(0.0);
  if (z >= 1.0) return;
  vec4 g = texelFetch(sampler2D(gbufferNormal, s5), px, 0);
  vec3 n = octDecode(g.xy);
  vec3 p = worldAt((vec2(px) + 0.5) / full, z);
  vec3 v = normalize(cb0.camera.xyz - p);
  vec3 e;
  lightParts(p, n, faceNormal(px, p, v), v, g.z, irradiance.rgb, e);
  environment.rgb = e;
}
