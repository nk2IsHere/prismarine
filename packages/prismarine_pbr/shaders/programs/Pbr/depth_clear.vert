#version 460 core
// One triangle that covers the viewport at the far depth.
layout(location = 0) in vec2 vsi0_POSITION0;

void main() {
  gl_Position = vec4(vsi0_POSITION0, 1.0, 1.0);
}
