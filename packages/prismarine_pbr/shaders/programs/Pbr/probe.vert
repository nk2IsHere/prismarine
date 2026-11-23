#version 460 core
// A disc that faces the camera at the place of each probe, one instance per
// probe. Each vertex has a corner from -1 to 1 in x and y.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

layout(location = 0) in vec2 vsi0_POSITION0;

uniform textureBuffer giProbes; // t0

layout(location = 0) out vec2 corner;
layout(location = 1) flat out int probe;

void main() {
  int i = gl_InstanceIndex;
  ivec3 c = ivec3(cb2.probeCounts.xyz);
  ivec3 g = ivec3(i % c.x, (i / c.x) % c.y, i / (c.x * c.y));
  vec4 data = texelFetch(giProbes, i);
  vec3 at = cb2.probeOrigin.xyz + vec3(g) * cb2.probeOrigin.w + data.xyz;
  vec3 f = cb2.cameraForward.xyz;
  vec3 right = normalize(cross(f, abs(f.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, f);
  float r = 0.12 * cb2.probeOrigin.w;
  corner = vsi0_POSITION0;
  probe = data.w > 0.5 ? i : -1;
  gl_Position = cb0.viewProjection * vec4(at + (right * corner.x + up * corner.y) * r, 1.0);
}
