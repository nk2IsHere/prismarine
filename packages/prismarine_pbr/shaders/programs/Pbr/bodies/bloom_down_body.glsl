// A bloom level from the larger level before it with the 13 taps of Jimenez.
// With FIRST the five groups of taps are weighted by the inverse of their
// luminance, which removes fireflies.
precision highp float;

uniform Bloom {
  // xy the texel size of the source
  vec4 texel;
} cb0;

uniform texture2D source; // t0
uniform sampler s0;
#define source_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

vec3 tap(vec2 offset) {
  return texture(sampler2D(source, s0), uv + offset * cb0.texel.xy).rgb;
}

// The weight of a group of taps. With FIRST it falls with the luminance of
// the group.
float weightOf(vec3 c) {
#ifdef FIRST
  return 1.0 / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722)));
#else
  return 1.0;
#endif
}

void main() {
  vec3 a = tap(vec2(-2.0, -2.0)), b = tap(vec2(0.0, -2.0)), c = tap(vec2(2.0, -2.0));
  vec3 d = tap(vec2(-2.0, 0.0)), e = tap(vec2(0.0, 0.0)), f = tap(vec2(2.0, 0.0));
  vec3 g = tap(vec2(-2.0, 2.0)), h = tap(vec2(0.0, 2.0)), i = tap(vec2(2.0, 2.0));
  vec3 j = tap(vec2(-1.0, -1.0)), k = tap(vec2(1.0, -1.0));
  vec3 l = tap(vec2(-1.0, 1.0)), m = tap(vec2(1.0, 1.0));
  vec3 groups[5] = vec3[5]((j + k + l + m) * 0.25, (a + b + d + e) * 0.25,
                           (b + c + e + f) * 0.25, (d + e + g + h) * 0.25,
                           (e + f + h + i) * 0.25);
  const float share[5] = float[5](0.5, 0.125, 0.125, 0.125, 0.125);
  vec3 s = vec3(0.0);
  float total = 0.0;
  for (int n = 0; n < 5; n++) {
    float w = share[n] * weightOf(groups[n]);
    s += groups[n] * w;
    total += w;
  }
  color = vec4(max(s / total, vec3(0.0)), 1.0);
}
