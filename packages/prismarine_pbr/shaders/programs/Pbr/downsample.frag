#version 460 core
// Half of the size of the source, the mean of each 2 by 2 texels by one
// bilinear read.
precision highp float;

uniform texture2D source; // t0
uniform sampler s1;
#define source_S s1

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
  color = vec4(textureLod(sampler2D(source, s1), uv, 0.0).rgb, 1.0);
}
