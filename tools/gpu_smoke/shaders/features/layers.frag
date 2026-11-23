#version 460
// A 2D array layer and a 3D texture slice, by a uniform.
uniform sampler2DArray layers;
uniform sampler3D volume;
uniform usampler3D grid;

uniform Pick {
  // x: array layer or depth slice; y: 0 array, 1 volume, 2 uint grid.
  vec4 pick;
} pick;

out vec4 frag_color;

void main() {
  int slice = int(pick.pick.x);
  if (pick.pick.y < 0.5) {
    frag_color = texture(layers, vec3(0.5, 0.5, pick.pick.x));
  } else if (pick.pick.y < 1.5) {
    frag_color = texelFetch(volume, ivec3(1, 1, slice), 0);
  } else {
    uint g = texelFetch(grid, ivec3(1, 1, slice), 0).x;
    frag_color = vec4(float(g & 255u), float((g >> 8u) & 255u), 0.0, 255.0) /
                 255.0;
  }
}
