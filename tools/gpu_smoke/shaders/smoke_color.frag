#version 460 core

precision highp float;

in vec4 v_color;
out vec4 frag_color;

void main() {
  frag_color = v_color;
}
