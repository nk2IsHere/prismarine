#version 460
// A texel at a coordinate and LOD from a uniform, for address modes, borders
// and LOD clamps.
uniform sampler2D source;

uniform At {
  vec4 at;
} at;

out vec4 frag_color;

void main() {
  frag_color = textureLod(source, at.at.xy, at.at.z);
}
