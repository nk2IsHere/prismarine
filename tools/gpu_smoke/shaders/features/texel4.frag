#version 460
// A four-channel unsigned texel buffer in a pixel stage (RGBA32UI).
uniform usamplerBuffer words;

out vec4 frag_color;

void main() {
  frag_color = vec4(texelFetch(words, 2)) / 255.0;
}
