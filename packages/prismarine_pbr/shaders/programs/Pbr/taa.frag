#version 460 core
precision highp float;
#include "Pbr/bodies/exposure.glsl"

// The temporal resolve. The nearest depth around the pixel is reprojected
// into the last frame with the cameras without jitter. The history is
// clipped to the colours around the pixel in YCoCg and blended with the
// current colour, both weighted by the inverse of their exposed luminance.
uniform Taa {
  mat4 inverseViewProjection;
  mat4 viewProjection;
  mat4 previousViewProjection;
  // xy the texel size, z the weight of the current frame, w the quality,
  // 0 low, 1 medium, 2 high
  vec4 params;
  // x the manual exposure, y 1 with auto exposure, z the compensation in EV
  vec4 exposure;
} cb0;

uniform texture2D hdr; // t0
uniform sampler s0;
#define hdr_S s0
uniform texture2D depth; // t1
#define depth_S s0
uniform texture2D history; // t2
uniform sampler s3;
#define history_S s3
uniform texture2D exposure; // t3
#define exposure_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

// A colour that is not a finite number becomes black. It would stay in the
// history for good.
vec3 finite(vec3 c) {
  return any(isnan(c)) || any(isinf(c)) ? vec3(0.0) : max(c, vec3(0.0));
}

vec3 toYCoCg(vec3 c) {
  return vec3(dot(c, vec3(0.25, 0.5, 0.25)), dot(c, vec3(0.5, 0.0, -0.5)),
              dot(c, vec3(-0.25, 0.5, -0.25)));
}

vec3 fromYCoCg(vec3 c) {
  return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// The colour of the pixel at [p] in YCoCg, after the exposure and a
// compression that keeps a bright pixel from ruling the box.
vec3 sampleAt(ivec2 p, ivec2 last, float e) {
  vec3 c = finite(texelFetch(sampler2D(hdr, s0), clamp(p, ivec2(0), last), 0).rgb) * e;
  return toYCoCg(c / (1.0 + max(c.r, max(c.g, c.b))));
}

// The history with a Catmull-Rom filter of five bilinear taps.
vec3 historyCatmullRom(vec2 at, vec2 size) {
  vec2 p = at * size;
  vec2 center = floor(p - 0.5) + 0.5;
  vec2 f = p - center;
  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
  vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
  vec2 w3 = f * f * (-0.5 + 0.5 * f);
  vec2 w12 = w1 + w2;
  vec2 t0 = (center - 1.0) / size;
  vec2 t3 = (center + 2.0) / size;
  vec2 t12 = (center + w2 / w12) / size;
  vec3 c = texture(sampler2D(history, s3), vec2(t12.x, t0.y)).rgb * (w12.x * w0.y);
  c += texture(sampler2D(history, s3), vec2(t0.x, t12.y)).rgb * (w0.x * w12.y);
  c += texture(sampler2D(history, s3), t12).rgb * (w12.x * w12.y);
  c += texture(sampler2D(history, s3), vec2(t3.x, t12.y)).rgb * (w3.x * w12.y);
  c += texture(sampler2D(history, s3), vec2(t12.x, t3.y)).rgb * (w12.x * w3.y);
  float w = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
  return max(c / w, vec3(0.0));
}

// Moves [h] towards [mean] until it is inside the box of half size [extent].
vec3 clipToBox(vec3 h, vec3 mean, vec3 extent) {
  vec3 d = h - mean;
  vec3 unit = abs(d / max(extent, vec3(1e-5)));
  float m = max(unit.x, max(unit.y, unit.z));
  return m > 1.0 ? mean + d / m : h;
}

void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  vec2 texel = cb0.params.xy;
  ivec2 last = ivec2(1.0 / texel) - 1;
  int quality = int(cb0.params.w + 0.5);
  float adapted = texelFetch(sampler2D(exposure, s0), ivec2(0), 0).r;
  float e = exposureFactor(adapted, cb0.exposure.x, cb0.exposure.y, cb0.exposure.z);

  // The nearest depth of the pixel and its four diagonal neighbours keeps
  // the edges of near objects with their own motion.
  ivec2 nearest = p;
  float d = texelFetch(sampler2D(depth, s0), p, 0).r;
  const ivec2 corners[4] = ivec2[4](ivec2(-1, -1), ivec2(1, -1), ivec2(-1, 1), ivec2(1, 1));
  for (int i = 0; i < 4; i++) {
    ivec2 q = clamp(p + corners[i], ivec2(0), last);
    float dq = texelFetch(sampler2D(depth, s0), q, 0).r;
    if (dq < d) {
      d = dq;
      nearest = q;
    }
  }
  vec2 ndc = (vec2(nearest) + 0.5) * texel * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
  vec4 world = cb0.inverseViewProjection * vec4(ndc, d, 1.0);
  world /= world.w;
  vec4 now = cb0.viewProjection * world;
  vec4 before = cb0.previousViewProjection * world;
  vec2 motion = (before.xy / before.w - now.xy / now.w) * vec2(0.5, -0.5);
  vec2 at = uv + motion;

  vec3 current = sampleAt(p, last, e);
  vec3 lo = current, hi = current, m1 = current, m2 = current * current;
  const ivec2 ring[8] = ivec2[8](ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1),
                                  ivec2(-1, -1), ivec2(1, -1), ivec2(-1, 1), ivec2(1, 1));
  int count = quality == 0 ? 4 : 8;
  for (int i = 0; i < count; i++) {
    vec3 c = sampleAt(p + ring[i], last, e);
    lo = min(lo, c);
    hi = max(hi, c);
    m1 += c;
    m2 += c * c;
  }

  float weight = cb0.params.z;
  if (any(lessThan(at, vec2(0.0))) || any(greaterThan(at, vec2(1.0)))) weight = 1.0;
  vec3 h = quality == 2 ? historyCatmullRom(at, 1.0 / texel)
                        : texture(sampler2D(history, s3), at).rgb;
  h = finite(h) * e;
  h = toYCoCg(h / (1.0 + max(h.r, max(h.g, h.b))));
  if (quality == 0) {
    h = clamp(h, lo, hi);
  } else {
    float n = float(count + 1);
    vec3 mean = m1 / n;
    vec3 deviation = sqrt(max(m2 / n - mean * mean, vec3(0.0)));
    h = clipToBox(h, mean, deviation * 1.25);
    h = clamp(h, lo, hi);
  }
  // The compressed colours already weigh by the inverse luminance.
  vec3 c = fromYCoCg(mix(h, current, weight));
  c = c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4);
  color = vec4(max(c / e, vec3(0.0)), 1.0);
}
