#version 460 core
#ifdef IMPELLER_TARGET_VULKAN
#extension GL_ARB_shader_viewport_layer_array : require
#endif

// Viewport arrays of release 7: each instance draws into the viewport its
// `tile` names. flutter_scene P34 turns the `mcsm_viewport_index` output into
// Metal's [[viewport_array_index]]; on Vulkan (release 8) the shader writes
// gl_ViewportIndex itself; elsewhere it is an output nobody reads.

uniform FrameInfo {
  vec4 scale;  // x: scale of the triangle in clip space
}
frame_info;

in vec2 position;
in vec2 offset;
in vec4 color;
in float tile;

out vec4 v_color;
out vec2 v_pos;
flat out uint mcsm_viewport_index;

void main() {
  v_color = color;
  vec2 p = position * frame_info.scale.x + offset;
  v_pos = p;
  gl_Position = vec4(p, 0.25 + 0.5 * p.x * p.y, 1.0);
#ifdef IMPELLER_TARGET_VULKAN
  gl_ViewportIndex = int(tile);
#endif
  mcsm_viewport_index = uint(tile);
}
