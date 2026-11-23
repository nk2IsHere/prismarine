#version 460 core

precision highp float;

uniform sampler2D source_texture;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  frag_color = texture(source_texture, v_uv);
}
