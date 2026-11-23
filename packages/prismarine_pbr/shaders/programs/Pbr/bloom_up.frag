#version 460 core
precision highp float;

// The smaller bloom level with a 3 by 3 tent, added to the larger level by
// the blend of the draw.
uniform Bloom {
  // xy the texel size of the source
  vec4 texel;
} cb0;

uniform texture2D source; // t0
uniform sampler s0;
#define source_S s0

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  vec2 t = cb0.texel.xy;
  vec3 s = texture(sampler2D(source, s0), uv).rgb * 4.0;
  s += (texture(sampler2D(source, s0), uv + vec2(-t.x, 0.0)).rgb +
        texture(sampler2D(source, s0), uv + vec2(t.x, 0.0)).rgb +
        texture(sampler2D(source, s0), uv + vec2(0.0, -t.y)).rgb +
        texture(sampler2D(source, s0), uv + vec2(0.0, t.y)).rgb) * 2.0;
  s += texture(sampler2D(source, s0), uv + vec2(-t.x, -t.y)).rgb +
       texture(sampler2D(source, s0), uv + vec2(t.x, -t.y)).rgb +
       texture(sampler2D(source, s0), uv + vec2(-t.x, t.y)).rgb +
       texture(sampler2D(source, s0), uv + vec2(t.x, t.y)).rgb;
  color = vec4(s / 16.0, 1.0);
}
