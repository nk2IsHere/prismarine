#version 460
// One texel of a float, unorm or depth texture, written to RGBA8.
uniform sampler2D source;

out vec4 frag_color;

void main() {
  frag_color = texture(source, vec2(0.5));
}
