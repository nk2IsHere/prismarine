#version 460
// Four instances, one per quadrant. The tint advances every two instances.
in vec2 position;
in vec4 tint;

out vec4 v_color;

void main() {
  vec2 quadrant = vec2(float(gl_InstanceIndex % 2), float(gl_InstanceIndex / 2));
  v_color = tint;
  gl_Position = vec4(position * 0.5 + (quadrant - 0.5), 0.0, 1.0);
}
