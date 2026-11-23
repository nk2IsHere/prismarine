#version 460 core
// The indirect light of the opaque surfaces, added to the direct light. It
// reads their normal, roughness, metallic value and base colour, the
// occlusion and the reflections. A debug view replaces the frame with one
// term.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D depth; // t0
uniform sampler s1;
#define depth_S s1
uniform texture2D gbufferNormal; // t1
#define gbufferNormal_S s1
uniform texture2D gbufferAlbedo; // t2
#define gbufferAlbedo_S s1
uniform texture2D ao; // t3
#define ao_S s1
uniform texture2D ssr; // t4
#define ssr_S s1
uniform texture2D giIrradiance; // t5
#define giIrradiance_S s1
uniform texture2D giDistance; // t6
#define giDistance_S s1
uniform textureBuffer giProbes; // t7
uniform texture2D skyEnv; // t8
uniform sampler s2;
#define skyEnv_S s2
uniform texture2D skySpecular; // t9
#define skySpecular_S s2
uniform texture2D skyIrradiance; // t10
#define skyIrradiance_S s2
uniform texture2D brdfLut; // t11
#define brdfLut_S s1

#include "Pbr/bodies/gi_probes.glsl"
#include "Pbr/bodies/sky_read.glsl"
#include "Pbr/bodies/indirect_light.glsl"

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  ivec2 px = ivec2(gl_FragCoord.xy);
  float z = texelFetch(sampler2D(depth, s1), px, 0).r;
  int view = int(cb2.misc.x);
  if (z >= 1.0) {
    color = vec4(0.0);
    if (view == 0) discard;
    return;
  }
  vec4 g = texelFetch(sampler2D(gbufferNormal, s1), px, 0);
  vec3 base = texelFetch(sampler2D(gbufferAlbedo, s1), px, 0).rgb;
  vec3 n = octDecode(g.xy);
  vec3 p = worldAt(uv, z);
  vec3 v = normalize(cb0.camera.xyz - p);
  float occlusion = cb2.switches.z > 0.5 ? textureLod(sampler2D(ao, s1), uv, 0.0).r : 1.0;
  vec4 reflection = cb2.switches.w > 0.5 ? textureLod(sampler2D(ssr, s1), uv, 0.0) : vec4(0.0);
  vec3 diffuse, specular;
  if (view == 1) {
    indirectTerms(p, n, v, vec3(1.0), 0.0, 1.0, occlusion, vec4(0.0), diffuse, specular);
    color = vec4(diffuse, 1.0);
  } else if (view == 2) {
    color = vec4(vec3(occlusion), 1.0);
  } else if (view == 3) {
    indirectTerms(p, n, v, vec3(1.0), 1.0, g.z, occlusion, reflection, diffuse, specular);
    color = vec4(specular, 1.0);
  } else {
    indirectTerms(p, n, v, base, g.w, g.z, occlusion, reflection, diffuse, specular);
    color = vec4(diffuse + specular, 0.0);
  }
}
