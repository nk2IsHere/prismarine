#version 460 core
precision highp float;

// Exposure, the ACES fit of Narkowicz and the sRGB encoding.
uniform Tonemap {
  // x the exposure
  vec4 params;
} cb0;

uniform texture2D hdr; // t0
uniform sampler s0;
#define hdr_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 encodeSrgb(vec3 c) {
  vec3 low = c * 12.92;
  vec3 high = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
  return mix(high, low, vec3(lessThanEqual(c, vec3(0.0031308))));
}

void main() {
  vec3 c = texture(sampler2D(hdr, s0), uv).rgb * cb0.params.x;
  color = vec4(encodeSrgb(aces(c)), 1.0);
}
