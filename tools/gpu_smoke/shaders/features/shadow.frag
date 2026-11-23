#version 460
// A comparison sampler that gives 1 where the reference passes against the
// depth.
uniform sampler2DShadow shadow;

uniform Ref {
  vec4 ref;
} ref;

out vec4 frag_color;

void main() {
  float lit = texture(shadow, vec3(0.5, 0.5, ref.ref.x));
  frag_color = vec4(lit, 0.0, 0.0, 1.0);
}
