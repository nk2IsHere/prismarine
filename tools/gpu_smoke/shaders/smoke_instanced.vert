#version 460 core

// A quad per instance: the vertex buffer holds the corners (per vertex),
// the instance buffer each instance's offset and colour (per instance).

uniform FrameInfo {
  vec4 scale;  // x: the quad's half size in clip space
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
