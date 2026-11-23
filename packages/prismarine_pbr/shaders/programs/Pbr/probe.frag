#version 460 core
// A probe as a sphere that shows its irradiance in the direction of each
// point of the sphere. A probe that is off is red.
precision highp float;
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D giIrradiance; // t0
uniform sampler s1;
#define giIrradiance_S s1

layout(location = 0) in vec2 corner;
layout(location = 1) flat in int probe;
layout(location = 0) out vec4 color;

void main() {
  float d = dot(corner, corner);
  if (d > 1.0) discard;
  if (probe < 0) {
    color = vec4(4.0, 0.0, 0.0, 1.0);
    return;
  }
  vec3 f = cb2.cameraForward.xyz;
  vec3 right = normalize(cross(f, abs(f.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, f);
  vec3 n = normalize(right * corner.x + up * corner.y - f * sqrt(1.0 - d));
  int tiles = int(cb2.probeCounts.w);
  vec2 tile = vec2(float(probe % tiles), float(probe / tiles)) * 8.0;
  vec2 uv = (tile + 1.0 + (octEncode(n) * 0.5 + 0.5) * 6.0) * cb2.atlas.xy;
  color = vec4(textureLod(sampler2D(giIrradiance, s1), uv, 0.0).rgb / PI, 1.0);
}
