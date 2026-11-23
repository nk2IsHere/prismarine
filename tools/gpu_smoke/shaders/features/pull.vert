#version 460
// A pulled vertex stage of release 10 without inputs. Its positions come
// from a storage buffer by vertex index. It passes the colour of the same
// buffer to the pixel stage by index.
layout(std430) readonly buffer RawPullRows {
  vec4 rows[];
} pullRows;

layout(location = 0) flat out uint v_row;

void main() {
  gl_Position = pullRows.rows[gl_VertexIndex];
  v_row = 4u;
}
