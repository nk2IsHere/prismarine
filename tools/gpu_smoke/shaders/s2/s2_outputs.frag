#version 460
// One value the compute pass wrote, read back through a fragment shader.
layout(std430) readonly buffer Outputs {
  vec4 values[];
} outputs;

out vec4 frag_color;

void main() {
  frag_color = outputs.values[17];
}
