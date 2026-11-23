#version 460
// A texture and samplers declared apart, one a comparison sampler.
uniform texture2D albedo;
uniform sampler albedo_sampler;
uniform texture2D depth_map;
uniform samplerShadow compare_sampler;

uniform Ref {
  vec4 ref;
} ref;

out vec4 frag_color;

void main() {
  vec4 c = texture(sampler2D(albedo, albedo_sampler), vec2(0.5));
  float lit = texture(sampler2DShadow(depth_map, compare_sampler),
                      vec3(0.5, 0.5, ref.ref.x));
  frag_color = vec4(c.rgb * lit, 1.0);
}
