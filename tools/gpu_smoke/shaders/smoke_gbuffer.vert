#version 460 core

// A quad per instance at its own depth (a G-buffer pass's depth test):
// offset, colour and depth per instance.

uniform FrameInfo {
  vec4 scale;  // x: the quad's half size in clip space
}
frame_info;

in vec2 position;
in vec2 offset;
in vec4 color;
in float depth;

out vec4 v_color;

void main() {
  v_color = color;
  gl_Position = vec4(position * frame_info.scale.x + offset, depth, 1.0);
}
