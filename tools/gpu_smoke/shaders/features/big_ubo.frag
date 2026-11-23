#version 460
// A 65,536-byte uniform block, the largest constant buffer of Direct3D 11.
// The limit of the stock impellerc is 6,208 bytes per shader.
layout(set = 0, binding = 0) uniform LightData {
  vec4 rows[4096];
} light_data;

out vec4 frag_color;

void main() {
  frag_color = light_data.rows[4000] + light_data.rows[5];
}
