// The shadow of a point light from the depth atlas. Each light with a slot
// has a row of six faces of a cube, in the order +x, -x, +y, -y, +z and -z.
// Each pair of opposite faces was drawn from the light position in
// pointPairs, which trails the light while it moves. pointShadow reads only
// the Frame block and the atlas, in any stage.
uniform texture2D pointShadowAtlas; // t5
#define pointShadowAtlas_S s4

const float pointShadowNear = 0.05;

// The light of [light] that reaches [worldPos], from 0 in shadow to 1.
// [normal] moves the test point off the surface. A zero normal does not.
float pointShadow(int light, vec3 worldPos, vec3 normal) {
  float slot = cb0.lightColor[light].w;
  if (slot < 0.5) return 1.0;
  vec4 lp = cb0.lightPosition[light];
  vec3 a0 = abs(worldPos - lp.xyz);
  int pair = a0.x >= a0.y && a0.x >= a0.z ? 0 : (a0.y >= a0.z ? 1 : 2);
  lp = cb0.pointPairs[int(slot - 0.5) * 3 + pair];
  ivec2 size = textureSize(sampler2DShadow(pointShadowAtlas, s4), 0);
  float tile = float(size.x) / 6.0;
  vec3 d = worldPos - lp.xyz;
  vec3 a = abs(d);
  float m = max(a.x, max(a.y, a.z));
  // The world size of a texel at this distance moves the point off the
  // surface and sets the depth bias.
  float texel = 2.0 * m / tile;
  d += normal * texel * 1.5;
  a = abs(d);
  int face;
  vec3 forward, up;
  if (a.x >= a.y && a.x >= a.z) {
    face = d.x > 0.0 ? 0 : 1;
    forward = vec3(sign(d.x), 0.0, 0.0);
    up = vec3(0.0, 1.0, 0.0);
  } else if (a.y >= a.z) {
    face = d.y > 0.0 ? 2 : 3;
    forward = vec3(0.0, sign(d.y), 0.0);
    up = vec3(0.0, 0.0, 1.0);
  } else {
    face = d.z > 0.0 ? 4 : 5;
    forward = vec3(0.0, 0.0, sign(d.z));
    up = vec3(0.0, 1.0, 0.0);
  }
  vec3 right = normalize(cross(forward, up));
  vec3 trueUp = cross(right, forward);
  m = dot(d, forward);
  vec2 ndc = vec2(dot(d, right), dot(d, trueUp)) / m;
  float far = lp.w;
  float biased = max(m - texel * cb0.shadowParams.w, pointShadowNear);
  float depth = far * (biased - pointShadowNear) / ((far - pointShadowNear) * biased);
  vec2 local = (ndc * vec2(0.5, -0.5) + 0.5) * tile;
  // The taps stay inside the tile.
  local = clamp(local, vec2(1.5), vec2(tile - 1.5));
  vec2 origin = vec2(float(face), slot - 1.0) * tile;
  vec2 inv = 1.0 / vec2(size);
  float lit = 0.0;
  const vec2 taps[4] = vec2[4](vec2(-0.5, -0.5), vec2(0.5, -0.5),
                               vec2(-0.5, 0.5), vec2(0.5, 0.5));
  for (int i = 0; i < 4; i++) {
    vec2 at = (origin + local + taps[i]) * inv;
    lit += texture(sampler2DShadow(pointShadowAtlas, s4), vec3(at, depth));
  }
  return lit * 0.25;
}
