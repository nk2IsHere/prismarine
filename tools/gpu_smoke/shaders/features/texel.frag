#version 460
// Texel buffers: an RGBA32F one indexed by an R32UI one.
uniform samplerBuffer lights;
uniform usamplerBuffer indices;

out vec4 frag_color;

void main() {
  uint i = texelFetch(indices, 3).x;
  frag_color = texelFetch(lights, int(i));
}
