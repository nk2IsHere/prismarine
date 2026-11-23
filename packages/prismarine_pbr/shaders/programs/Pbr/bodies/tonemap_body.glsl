// The tone map pass with bloom, exposure, a tone map curve, the sRGB
// encoding and a dither of half a level. With HISTORY the pass also keeps the resolved
// image for the next frame's TAA.
precision highp float;
#include "Pbr/bodies/exposure.glsl"

uniform Tonemap {
  // x the manual exposure, y 1 with auto exposure, z the compensation in EV,
  // w the curve, 0 ACES fit, 1 ACES, 2 AgX, 3 PBR Neutral
  vec4 params;
  // x the bloom strength, y one over the bloom levels, zw the texel size of
  // the first bloom level
  vec4 bloom;
} cb0;

uniform texture2D hdr; // t0
uniform sampler s0;
#define hdr_S s0
uniform texture2D bloom; // t1
#define bloom_S s0
uniform texture2D exposure; // t2
#define exposure_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
#ifdef HISTORY
layout(location = 1) out vec4 history;
#endif

vec3 acesFit(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// The fit of Stephen Hill. The matrices are given by rows and multiply a
// row vector.
vec3 acesHill(vec3 c) {
  const mat3 toAp1 = mat3(
      0.59719, 0.35458, 0.04823,
      0.07600, 0.90834, 0.01566,
      0.02840, 0.13383, 0.83777);
  const mat3 fromAp1 = mat3(
      1.60475, -0.53108, -0.07367,
      -0.10208, 1.10813, -0.00605,
      -0.00327, -0.07276, 1.07602);
  c = c * toAp1;
  vec3 a = c * (c + 0.0245786) - 0.000090537;
  vec3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
  return clamp((a / b) * fromAp1, 0.0, 1.0);
}

// AgX of Troy Sobotka with the polynomial base contrast of Benjamin Wrensch.
// The curve gives display values with a gamma of 2.2, made linear for the
// sRGB encoding.
vec3 agx(vec3 c) {
  const mat3 inset = mat3(
      0.842479062253094, 0.0423282422610123, 0.0423756549057051,
      0.0784335999999992, 0.878468636469772, 0.0784336,
      0.0792237451477643, 0.0791661274605434, 0.879142973793104);
  const mat3 outset = mat3(
      1.19687900512017, -0.0528968517574562, -0.0529716355144438,
      -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
      -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
  const float lo = -12.47393, hi = 4.026069;
  vec3 x = clamp(log2(max(inset * c, vec3(1e-10))), lo, hi);
  x = (x - lo) / (hi - lo);
  vec3 x2 = x * x;
  vec3 x4 = x2 * x2;
  x = 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x +
      0.4298 * x2 + 0.1191 * x - 0.00232;
  return pow(clamp(outset * x, 0.0, 1.0), vec3(2.2));
}

vec3 pbrNeutral(vec3 c) {
  const float start = 0.76;
  const float desaturation = 0.15;
  float x = min(c.r, min(c.g, c.b));
  float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
  c -= offset;
  float peak = max(c.r, max(c.g, c.b));
  if (peak < start) return c;
  const float d = 1.0 - start;
  float top = 1.0 - d * d / (peak + d - start);
  c *= top / peak;
  float g = 1.0 - 1.0 / (desaturation * (peak - top) + 1.0);
  return mix(c, vec3(top), g);
}

vec3 encodeSrgb(vec3 c) {
  vec3 low = c * 12.92;
  vec3 high = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
  return mix(high, low, vec3(lessThanEqual(c, vec3(0.0031308))));
}

// A 3 by 3 tent over the first bloom level.
vec3 bloomAt(vec2 at) {
  vec2 t = cb0.bloom.zw;
  vec3 s = texture(sampler2D(bloom, s0), at).rgb * 4.0;
  s += (texture(sampler2D(bloom, s0), at + vec2(-t.x, 0.0)).rgb +
        texture(sampler2D(bloom, s0), at + vec2(t.x, 0.0)).rgb +
        texture(sampler2D(bloom, s0), at + vec2(0.0, -t.y)).rgb +
        texture(sampler2D(bloom, s0), at + vec2(0.0, t.y)).rgb) * 2.0;
  s += texture(sampler2D(bloom, s0), at + vec2(-t.x, -t.y)).rgb +
       texture(sampler2D(bloom, s0), at + vec2(t.x, -t.y)).rgb +
       texture(sampler2D(bloom, s0), at + vec2(-t.x, t.y)).rgb +
       texture(sampler2D(bloom, s0), at + vec2(t.x, t.y)).rgb;
  return s / 16.0;
}

void main() {
  vec3 c = texelFetch(sampler2D(hdr, s0), ivec2(gl_FragCoord.xy), 0).rgb;
#ifdef HISTORY
  history = vec4(c, 1.0);
#endif
  if (cb0.bloom.x > 0.0) {
    c = mix(c, bloomAt(uv) * cb0.bloom.y, cb0.bloom.x);
  }
  float adapted = texelFetch(sampler2D(exposure, s0), ivec2(0), 0).r;
  c *= exposureFactor(adapted, cb0.params.x, cb0.params.y, cb0.params.z);
  int curve = int(cb0.params.w + 0.5);
  if (curve == 1) {
    c = acesHill(c);
  } else if (curve == 2) {
    c = agx(c);
  } else if (curve == 3) {
    c = pbrNeutral(c);
  } else {
    c = acesFit(c);
  }
  c = encodeSrgb(clamp(c, 0.0, 1.0));
  // Interleaved gradient noise of Jimenez breaks the bands of smooth fog.
  float n = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  c += (n - 0.5) / 255.0;
  color = vec4(c, 1.0);
}
