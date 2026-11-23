#version 460 core
#ifdef IMPELLER_TARGET_VULKAN
#extension GL_ARB_shader_viewport_layer_array : require
#endif

// Viewport arrays of release 7. Each instance draws into the viewport of its
// `tile`. The build hook turns the `viewport_index` output into the
// [[viewport_array_index]] of Metal. On Vulkan (release 8) the shader writes
// gl_ViewportIndex itself. Elsewhere nobody reads the output.

uniform FrameInfo {
  vec4 scale;  // x is the scale of the triangle in clip space
}
frame_info;

in vec2 position;
in vec2 offset;
in vec4 color;
in float tile;

out vec4 v_color;
out vec2 v_pos;
flat out uint viewport_index;

void main() {
  v_color = color;
  vec2 p = position * frame_info.scale.x + offset;
  v_pos = p;
  gl_Position = vec4(p, 0.25 + 0.5 * p.x * p.y, 1.0);
#ifdef IMPELLER_TARGET_VULKAN
  gl_ViewportIndex = int(tile);
#endif
  viewport_index = uint(tile);
}
