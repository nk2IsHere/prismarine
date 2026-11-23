#version 460
// A pulled vertex stage of release 10: no inputs, its positions
// from a storage buffer by vertex index, and the same buffer's colour handed
// to the pixel stage by index.
layout(std430) readonly buffer RawPullRows {
  vec4 rows[];
} pullRows;

layout(location = 0) flat out uint v_row;

void main() {
  gl_Position = pullRows.rows[gl_VertexIndex];
  v_row = 4u;
}
