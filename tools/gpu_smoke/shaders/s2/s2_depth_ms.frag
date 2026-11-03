#version 460
// Both samples of a 2x MSAA depth target, read in a later pass.
uniform sampler2DMS depth_ms;

out vec4 frag_color;

void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  frag_color = vec4(texelFetch(depth_ms, p, 0).r, texelFetch(depth_ms, p, 1).r,
                    0.0, 1.0);
}
