// The lit pixel stage: glTF metallic-roughness with a GGX distribution,
// height-correlated Smith visibility and Schlick Fresnel, a sun with a
// filtered shadow map, point lights with the range falloff of
// KHR_lights_punctual and shadows from an atlas and emission. An opaque
// draw writes its normal, roughness, metallic value and base colour for the
// indirect pass. A blended draw, with BLENDED defined, adds its indirect
// light itself.
precision highp float;
#include "Pbr/bodies/blocks.glsl"
#ifdef BLENDED
#include "Pbr/bodies/indirect_block.glsl"
#endif

uniform texture2D baseColor; // t0
uniform sampler s0;
#define baseColor_S s0
uniform texture2D normalMap; // t1
#define normalMap_S s0
uniform texture2D metallicRoughness; // t2
#define metallicRoughness_S s0
uniform texture2D emissiveMap; // t3
#define emissiveMap_S s0
uniform texture2D shadowMap; // t4
uniform samplerShadow s4;
#define shadowMap_S s4
#include "Pbr/bodies/point_shadow.glsl"

layout(location = 0) in vec3 worldPosition;
layout(location = 1) in vec3 worldNormal;
layout(location = 2) in vec4 worldTangent;
layout(location = 3) in vec2 uv;

#ifdef BLENDED
uniform texture2D giIrradiance; // t6
uniform sampler s5;
#define giIrradiance_S s5
uniform texture2D giDistance; // t7
#define giDistance_S s5
uniform textureBuffer giProbes; // t8
uniform texture2D skyEnv; // t9
uniform sampler s6;
#define skyEnv_S s6
uniform texture2D skySpecular; // t10
#define skySpecular_S s6
uniform texture2D skyIrradiance; // t11
#define skyIrradiance_S s6
uniform texture2D brdfLut; // t12
#define brdfLut_S s5
#include "Pbr/bodies/gi_probes.glsl"
#include "Pbr/bodies/sky_read.glsl"
#include "Pbr/bodies/indirect_light.glsl"
#else
const float PI = 3.14159265;

vec2 signNotZero(vec2 v) {
  return vec2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
}

vec2 octEncode(vec3 n) {
  n /= abs(n.x) + abs(n.y) + abs(n.z);
  vec2 o = n.xz;
  if (n.y < 0.0) o = (1.0 - abs(o.yx)) * signNotZero(o);
  return o;
}
#endif

layout(location = 0) out vec4 color;
#ifndef BLENDED
layout(location = 1) out vec4 gbufferNormal;
layout(location = 2) out vec4 gbufferAlbedo;
#endif

float distributionGgx(float nh, float a2) {
  float f = (nh * a2 - nh) * nh + 1.0;
  return a2 / (PI * f * f);
}

float visibilitySmith(float nv, float nl, float a2) {
  float v = nl * sqrt(nv * nv * (1.0 - a2) + a2);
  float l = nv * sqrt(nl * nl * (1.0 - a2) + a2);
  return 0.5 / max(v + l, 1e-5);
}

// The light that leaves the surface towards v for light from l of unit
// intensity.
vec3 surface(vec3 n, vec3 v, vec3 l, vec3 albedo, vec3 f0, float a2) {
  float nl = max(dot(n, l), 0.0);
  if (nl <= 0.0) return vec3(0.0);
  vec3 h = normalize(v + l);
  float nv = max(dot(n, v), 1e-4);
  float nh = max(dot(n, h), 0.0);
  float vh = max(dot(v, h), 0.0);
  vec3 f = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
  vec3 specular = f * distributionGgx(nh, a2) * visibilitySmith(nv, nl, a2);
  vec3 diffuse = (1.0 - f) * albedo / PI;
  return (diffuse + specular) * nl;
}

float sunShadow(vec3 p, vec3 n) {
  if (cb0.sunDirection.w < 0.5) return 1.0;
  float slope = 1.0 - max(dot(n, cb0.sunDirection.xyz), 0.0);
  vec3 offset = n * cb0.shadowParams.z * (0.2 + slope);
  vec4 s = cb0.shadowMatrix * vec4(p + offset, 1.0);
  if (s.z >= 1.0) return 1.0;
  float d = s.z - cb0.shadowParams.y;
  float texel = cb0.shadowParams.x;
  float lit = 0.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 at = s.xy + vec2(float(x), float(y)) * texel;
      lit += texture(sampler2DShadow(shadowMap, s4), vec3(at, d));
    }
  }
  return lit / 9.0;
}

void main() {
  vec4 base = texture(sampler2D(baseColor, s0), uv) * cb1.baseColorFactor;
#ifdef MASKED
  if (base.a < cb1.material.z) discard;
#endif
  vec3 n = normalize(worldNormal);
  if (!gl_FrontFacing) n = -n;
  vec3 t = worldTangent.xyz - n * dot(n, worldTangent.xyz);
  t = dot(t, t) > 1e-12 ? normalize(t) : vec3(1.0, 0.0, 0.0);
  vec3 b = cross(n, t) * (worldTangent.w < 0.0 ? -1.0 : 1.0);
  vec3 m = texture(sampler2D(normalMap, s0), uv).xyz * 2.0 - 1.0;
  m.xy *= cb1.material.w;
  n = normalize(mat3(t, b, n) * m);

  vec4 mr = texture(sampler2D(metallicRoughness, s0), uv);
  float metallic = clamp(cb1.material.x * mr.b, 0.0, 1.0);
  float roughness = clamp(cb1.material.y * mr.g, 0.04, 1.0);
  float a2 = roughness * roughness * roughness * roughness;
  // The specular anti-aliasing of Kaplanyan and Tokuyoshi widens the lobe
  // where the normal turns within a pixel, such as on the pits of the stone.
  vec3 dndx = dFdx(n), dndy = dFdy(n);
  float variance = 0.25 * (dot(dndx, dndx) + dot(dndy, dndy));
  a2 = clamp(a2 + min(2.0 * variance, 0.18), 0.0, 1.0);
  vec3 albedo = base.rgb * (1.0 - metallic);
  vec3 f0 = mix(vec3(0.04), base.rgb, metallic);
  vec3 v = normalize(cb0.camera.xyz - worldPosition);

  vec3 sun = cb0.sunDirection.xyz;
  vec3 result = surface(n, v, sun, albedo, f0, a2) * cb0.sunColor.rgb *
      sunShadow(worldPosition, normalize(worldNormal));
  int count = int(cb0.groundColor.w);
  for (int i = 0; i < 16; i++) {
    if (i >= count) break;
    vec4 lp = cb0.lightPosition[i];
    vec3 d = lp.xyz - worldPosition;
    float dist2 = max(dot(d, d), 1e-4);
    float r = dist2 / (lp.w * lp.w);
    float falloff = clamp(1.0 - r * r, 0.0, 1.0) / dist2;
    if (falloff <= 0.0) continue;
    result += surface(n, v, d * inversesqrt(dist2), albedo, f0, a2) *
        cb0.lightColor[i].rgb * falloff *
        pointShadow(i, worldPosition, normalize(worldNormal));
  }
  result += texture(sampler2D(emissiveMap, s0), uv).rgb * cb1.emissive.rgb;
#ifdef BLENDED
  vec3 diffuse, specular;
  vec3 face = normalize(worldNormal) * (gl_FrontFacing ? 1.0 : -1.0);
  indirectTerms(worldPosition, n, face, v, base.rgb, metallic, roughness, 1.0, vec4(0.0), diffuse, specular);
  result += diffuse + specular;
#else
  gbufferNormal = vec4(octEncode(n), roughness, metallic);
  gbufferAlbedo = vec4(base.rgb, 1.0);
#endif
  color = vec4(result, base.a);
}
