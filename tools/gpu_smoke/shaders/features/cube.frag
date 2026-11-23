#version 460
// The face +X of the cube of a cube array that a uniform selects.
uniform samplerCubeArray cubes;

uniform At {
  vec4 at;
} at;

out vec4 frag_color;

void main() {
  frag_color = texture(cubes, vec4(1.0, 0.0, 0.0, at.at.x));
}
