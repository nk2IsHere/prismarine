#version 460 core

// A quad per instance. The vertex buffer holds the corners per vertex. The
// instance buffer holds the offset and colour of each instance.

uniform FrameInfo {
  vec4 scale;  // x is the half size of the quad in clip space
}
frame_info;

in vec2 position;
in vec2 offset;
in vec4 color;

out vec4 v_color;

void main() {
  v_color = color;
  gl_Position = vec4(position * frame_info.scale.x + offset, 0.0, 1.0);
}
