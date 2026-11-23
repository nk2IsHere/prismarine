#version 460 core
#include "Pbr/bodies/blocks.glsl"

layout(location = 0) in vec3 vsi0_POSITION0;
layout(location = 1) in vec3 vsi1_NORMAL0;
layout(location = 2) in vec4 vsi2_TANGENT0;
layout(location = 3) in vec2 vsi3_TEXCOORD0;

layout(location = 0) out vec3 worldPosition;
layout(location = 1) out vec3 worldNormal;
layout(location = 2) out vec4 worldTangent;
layout(location = 3) out vec2 uv;

void main() {
  vec4 w = cb1.model * vec4(vsi0_POSITION0, 1.0);
  worldPosition = w.xyz;
  worldNormal = mat3(cb1.normalMatrix) * vsi1_NORMAL0;
  worldTangent = vec4(mat3(cb1.model) * vsi2_TANGENT0.xyz, vsi2_TANGENT0.w);
  uv = vsi3_TEXCOORD0;
  gl_Position = cb0.viewProjection * w;
}
