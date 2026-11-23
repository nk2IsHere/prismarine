#version 460
#extension GL_ARB_shader_viewport_layer_array : require
// The quad once per instance, each into the layer of its instance index.
in vec2 position;

layout(location = 0) flat out int v_layer;

void main() {
  v_layer = gl_InstanceIndex;
  gl_Layer = gl_InstanceIndex;
  gl_Position = vec4(position, 0.0, 1.0);
}
