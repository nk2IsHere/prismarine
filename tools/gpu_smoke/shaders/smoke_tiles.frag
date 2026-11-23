#version 460 core

// The interpolated colour and position. Coverage and interpolation both show
// in the bytes.

precision highp float;

in vec4 v_color;
in vec2 v_pos;
out vec4 frag_color;

void main() {
  frag_color = vec4(v_color.rgb * (0.5 + 0.5 * v_pos.x),
                    0.5 + 0.5 * v_pos.y);
}
