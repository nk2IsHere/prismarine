#version 460 core
precision highp float;
#include "Pbr/bodies/blocks.glsl"

uniform texture2D baseColor; // t0
uniform sampler s0;
#define baseColor_S s0

layout(location = 0) in vec2 uv;

void main() {
  float a = texture(sampler2D(baseColor, s0), uv).a * cb1.baseColorFactor.a;
  if (a < cb1.material.z) discard;
}
