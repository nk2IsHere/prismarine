#version 460
// One layer of an array at a LOD.
uniform sampler2DArray layers;

uniform At {
  vec4 at;
} at;

out vec4 frag_color;

void main() {
  frag_color = textureLod(layers, vec3(0.5, 0.5, at.at.x), at.at.y);
}
