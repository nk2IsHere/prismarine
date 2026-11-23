#version 460
#extension GL_ARB_shader_draw_parameters : require
// An invariant position, a clip distance that cuts the left half and the
// base instance as an output.
in vec2 position;

layout(location = 0) flat out int v_base;
out float gl_ClipDistance[4];
invariant gl_Position;

void main() {
  v_base = gl_BaseInstanceARB;
  gl_ClipDistance[0] = position.x + 0.0001;
  gl_ClipDistance[1] = 1.0;
  gl_ClipDistance[2] = 1.0;
  gl_ClipDistance[3] = 1.0;
  gl_Position = vec4(position, 0.0, 1.0);
}
