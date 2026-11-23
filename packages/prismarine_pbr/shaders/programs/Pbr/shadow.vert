#version 460 core
#include "Pbr/bodies/blocks.glsl"

// The shadow pass draws with the sun's matrix in the frame's view and
// projection.
layout(location = 0) in vec3 vsi0_POSITION0;
layout(location = 1) in vec2 vsi3_TEXCOORD0;

layout(location = 0) out vec2 uv;

void main() {
  uv = vsi3_TEXCOORD0;
  gl_Position = cb0.viewProjection * (cb1.model * vec4(vsi0_POSITION0, 1.0));
}
