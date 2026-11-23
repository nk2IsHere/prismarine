#version 460 core
// The sky where nothing else is drawn, with the sun's disc.
precision highp float;
#include "Pbr/bodies/frame_block.glsl"
#include "Pbr/bodies/indirect_block.glsl"

uniform texture2D skyEnv; // t0
uniform sampler s6;
#define skyEnv_S s6
uniform texture2D skySpecular; // t1
#define skySpecular_S s6
uniform texture2D skyIrradiance; // t2
#define skyIrradiance_S s6

#include "Pbr/bodies/sky_read.glsl"

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  vec3 d = normalize(worldAt(uv, 1.0) - cb0.camera.xyz);
  vec3 c = skyRadiance(d, 0.0);
  // A disc of 0.27 degrees with a soft rim.
  float mu = dot(d, normalize(cb0.sunDirection.xyz));
  float disc = smoothstep(0.999985, 0.999992, mu);
  c += cb0.sunColor.rgb * disc * 2000.0;
  color = vec4(c, 1.0);
}
