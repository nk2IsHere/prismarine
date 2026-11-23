#version 460
// As pull.vert, with one vertex input, the index 0 to 191 that a renderer
// feeds while a stage without inputs cannot load.
layout(location = 0) in float pull_index;
layout(std430) readonly buffer RawPullRows {
  vec4 rows[];
} pullRows;

layout(location = 0) flat out uint v_row;

void main() {
  gl_Position = pullRows.rows[uint(pull_index)];
  v_row = 4u;
}
