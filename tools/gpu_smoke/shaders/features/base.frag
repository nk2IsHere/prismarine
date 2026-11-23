#version 460
// The base instance as red.
layout(location = 0) flat in int v_base;

out vec4 frag_color;

void main() {
  frag_color = vec4(float(v_base) * 40.0 / 255.0, 0.5, 0.25, 1.0);
}
