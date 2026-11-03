#version 460
// A colour per layer.
layout(location = 0) flat in int v_layer;

out vec4 frag_color;

void main() {
  frag_color = vec4(float(v_layer) * 0.25, 1.0 - float(v_layer) * 0.25, 0.5,
                    1.0);
}
