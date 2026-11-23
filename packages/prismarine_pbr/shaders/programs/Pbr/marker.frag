#version 460 core
precision highp float;

layout(location = 0) in vec2 corner;
layout(location = 1) in vec3 color;

layout(location = 0) out vec4 result;

// A bright core in the hue of the light that fades to the edge.
void main() {
  float d = dot(corner, corner);
  if (d > 1.0) discard;
  float peak = max(max(color.r, color.g), max(color.b, 1e-4));
  float a = (1.0 - d) * (1.0 - d);
  result = vec4(color / peak * 6.0 * a + vec3(2.0 * a * a), 0.0);
}
