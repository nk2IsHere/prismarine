#version 460
// A pulled pixel stage with the same storage buffer as the vertex stage,
// bound in both, a second one of its own and a uniform block beside them.
layout(std430) readonly buffer RawPullRows {
  vec4 rows[];
} pullRows;
layout(std430) readonly buffer RawPullWords {
  uint words[];
} pullWords;
uniform PullScale {
  vec4 scale;
} pullScale;

layout(location = 0) flat in uint v_row;
out vec4 frag_color;

void main() {
  frag_color = pullRows.rows[v_row] * pullScale.scale +
               vec4(float(pullWords.words[1]) / 255.0, 0.0, 0.0, 0.0);
}
