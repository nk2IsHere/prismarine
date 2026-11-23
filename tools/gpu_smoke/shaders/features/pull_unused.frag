#version 460
// A pulled pixel stage that declares resources that it does not read, as a
// shared pulled preamble does. Metal reflects them without an index. Binding
// them crashes the driver on an engine before release 10.
layout(std430) readonly buffer RawPullRows {
  vec4 rows[];
} pullRows;
layout(std430) readonly buffer RawPullUnused {
  uint words[];
} pullUnused;
uniform usamplerBuffer unusedWords;

layout(location = 0) flat in uint v_row;
out vec4 frag_color;

void main() {
  frag_color = pullRows.rows[v_row];
}
