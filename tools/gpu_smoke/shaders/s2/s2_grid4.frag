#version 460
// A uint 3D texel at (1, 1, 1) as colour.
uniform usampler3D grid4;

out vec4 frag_color;

void main() {
  uvec4 g = texelFetch(grid4, ivec3(1, 1, 1), 0);
  frag_color = vec4(g) * 50.0 / 255.0;
}
