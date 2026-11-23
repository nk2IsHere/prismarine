// The helpers of the indirect light that read no block.
const float PI = 3.14159265;

vec2 signNotZero(vec2 v) {
  return vec2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
}

// The octahedral form of a unit vector, with y as the axis of the fold, from
// -1 to 1.
vec2 octEncode(vec3 n) {
  n /= abs(n.x) + abs(n.y) + abs(n.z);
  vec2 o = n.xz;
  if (n.y < 0.0) o = (1.0 - abs(o.yx)) * signNotZero(o);
  return o;
}

vec3 octDecode(vec2 o) {
  vec3 n = vec3(o.x, 1.0 - abs(o.x) - abs(o.y), o.y);
  if (n.y < 0.0) n.xz = (1.0 - abs(n.zx)) * signNotZero(n.xz);
  return normalize(n);
}

// The place of direction d in an equirectangular map, u around y and v
// from up to down.
vec2 equirect(vec3 d) {
  return vec2(atan(d.z, d.x) * (0.5 / PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
}

vec3 equirectDirection(vec2 uv) {
  float phi = (uv.x - 0.5) * 2.0 * PI;
  float theta = uv.y * PI;
  return vec3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
}

// Direction i of n in a spherical Fibonacci pattern.
vec3 fibonacci(int i, int n) {
  float phi = 2.0 * PI * fract(float(i) * 0.6180339887);
  float y = 1.0 - (2.0 * float(i) + 1.0) / float(n);
  float r = sqrt(max(1.0 - y * y, 0.0));
  return vec3(r * cos(phi), y, r * sin(phi));
}
