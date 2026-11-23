#version 460
// A pulled pixel stage that declares resources it never reads (the shared
// pulled preamble does): Metal reflects them without an index, and binding
// them crashed the driver before release 10.
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
