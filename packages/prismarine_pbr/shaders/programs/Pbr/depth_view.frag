#version 460 core
precision highp float;

// The depth of the shadow map as grey, near white and far black.
uniform texture2D shadowMap; // t0
uniform sampler s0;
#define shadowMap_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  float d = texture(sampler2D(shadowMap, s0), uv).r;
  color = vec4(vec3(1.0 - d), 1.0);
}
