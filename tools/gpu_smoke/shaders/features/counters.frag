#version 460
// Reads back the atomic counters and a written texel.
uniform usamplerBuffer counters;
uniform samplerBuffer values;

out vec4 frag_color;

void main() {
  uint added = texelFetch(counters, 0).x;
  uint exchanged = texelFetch(counters, 1).x;
  vec4 v = texelFetch(values, 10);
  frag_color = vec4(float(added) / 255.0, float(exchanged) / 255.0, v.z, 1.0);
}
