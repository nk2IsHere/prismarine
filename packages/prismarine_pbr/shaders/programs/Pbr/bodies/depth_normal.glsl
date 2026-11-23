// The normal of the face under a pixel from the depth buffer. It needs the
// Indirect block and the texture depth with the sampler s5.

vec3 depthPosition(ivec2 px) {
  ivec2 size = ivec2(cb2.view.xy);
  px = clamp(px, ivec2(0), size - 1);
  float z = texelFetch(sampler2D(depth, s5), px, 0).r;
  return worldAt((vec2(px) + 0.5) * cb2.view.zw, z);
}

// The normal of the face at pixel px with world position p, on the side of
// the direction toward. Each axis takes the neighbour nearer in depth, which
// keeps the edges of objects out.
vec3 faceNormal(ivec2 px, vec3 p, vec3 toward) {
  vec3 l = depthPosition(px - ivec2(1, 0)), r = depthPosition(px + ivec2(1, 0));
  vec3 u = depthPosition(px - ivec2(0, 1)), d = depthPosition(px + ivec2(0, 1));
  vec3 dx = distance(l, p) < distance(r, p) ? p - l : r - p;
  vec3 dy = distance(u, p) < distance(d, p) ? p - u : d - p;
  vec3 n = normalize(cross(dy, dx));
  return dot(n, toward) < 0.0 ? -n : n;
}
