#version 460
// A constant colour (and depth from the vertex stage).
uniform Paint {
  vec4 color;
} paint;

out vec4 frag_color;

void main() {
  frag_color = paint.color;
}
