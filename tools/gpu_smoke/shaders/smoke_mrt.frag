#version 460 core

// Two targets in one pass: the colour in the first (RGBA8), its green
// channel times 4 as a float in the second (R32F), as a G-buffer writes a
// colour and a depth.

precision highp float;

in vec4 v_color;
layout(location = 0) out vec4 frag_color;
layout(location = 1) out vec4 frag_value;

void main() {
  frag_color = v_color;
  frag_value = vec4(v_color.g * 4.0, 0.0, 0.0, 1.0);
}
