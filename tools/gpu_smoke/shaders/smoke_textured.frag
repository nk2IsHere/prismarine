#version 460 core

// A material-like fragment for the draw benchmark with a uniform block and
// three textures.

precision highp float;

uniform sampler2D map_a;
uniform sampler2D map_b;
uniform sampler2D map_c;

uniform MaterialInfo {
  vec4 tint;
}
material;

in vec4 v_color;
out vec4 frag_color;

void main() {
  vec2 uv = gl_FragCoord.xy / 64.0;
  frag_color = v_color * material.tint * texture(map_a, uv) *
               texture(map_b, uv) * texture(map_c, uv);
}
