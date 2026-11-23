#version 460 core
// One triangle that covers the view at the far plane, its corners given as
// positions.
layout(location = 0) in vec2 vsi0_POSITION0;
layout(location = 0) out vec2 uv;

void main() {
  uv = vsi0_POSITION0 * vec2(0.5, -0.5) + 0.5;
  gl_Position = vec4(vsi0_POSITION0, 1.0, 1.0);
}
