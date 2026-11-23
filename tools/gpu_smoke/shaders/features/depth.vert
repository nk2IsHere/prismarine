#version 460
// The quad at a depth from a uniform.
in vec2 position;

uniform Depth {
  vec4 depth;
} depth;

void main() {
  gl_Position = vec4(position, depth.depth.x, 1.0);
}
