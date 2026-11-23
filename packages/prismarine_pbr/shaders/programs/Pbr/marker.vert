#version 460 core
#include "Pbr/bodies/frame_block.glsl"

// A disc that faces the camera at the place of each point light. Each
// vertex has a corner from -1 to 1 in x and y and the index of its light in z.
layout(location = 0) in vec3 vsi0_POSITION0;

layout(location = 0) out vec2 corner;
layout(location = 1) out vec3 color;

void main() {
  int i = int(vsi0_POSITION0.z + 0.5);
  corner = vsi0_POSITION0.xy;
  if (i >= int(cb0.groundColor.w) || cb0.markers.w < 0.5) {
    color = vec3(0.0);
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
  }
  vec4 c = cb0.viewProjection * vec4(cb0.lightPosition[i].xyz, 1.0);
  c.xy += vsi0_POSITION0.xy * cb0.markers.z * cb0.markers.xy;
  color = cb0.lightColor[i].rgb;
  gl_Position = c;
}
