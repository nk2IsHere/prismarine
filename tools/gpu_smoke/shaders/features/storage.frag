#version 460
// A read-only storage buffer in a fragment shader.
layout(std430) readonly buffer Cascades {
  vec4 rows[];
} cascades;

in vec2 v_uv;
out vec4 frag_color;

void main() {
  // A fine derivative too, which is zero on a flat input.
  frag_color = cascades.rows[3] + vec4(dFdxFine(0.0) + dFdyFine(0.0));
}
