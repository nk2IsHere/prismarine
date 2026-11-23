#version 460
// A 65,536-byte uniform block: Direct3D 11's largest constant buffer (S2's
// light data is 12,288 bytes; impellerc's old limit was 6,208 in all).
layout(set = 0, binding = 0) uniform LightData {
  vec4 rows[4096];
} light_data;

out vec4 frag_color;

void main() {
  frag_color = light_data.rows[4000] + light_data.rows[5];
}
