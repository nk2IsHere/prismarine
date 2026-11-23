// The irradiance of the probes at a point. It needs the Indirect block, the
// textures giIrradiance and giDistance with a linear clamped sampler s5 and
// the texel buffer giProbes.

ivec3 probeGrid() {
  return ivec3(cb2.probeCounts.xyz);
}

vec3 probePosition(int i) {
  ivec3 c = probeGrid();
  ivec3 g = ivec3(i % c.x, (i / c.x) % c.y, i / (c.x * c.y));
  return cb2.probeOrigin.xyz + vec3(g) * cb2.probeOrigin.w + texelFetch(giProbes, i).xyz;
}

// The texture coordinates of direction d in the tile of a probe, a tile of
// side tile with inner texels inside a border of one texel.
vec2 probeTexel(int probe, vec3 d, float tile, float inner, vec2 texel) {
  int tiles = int(cb2.probeCounts.w);
  vec2 corner = vec2(float(probe % tiles), float(probe / tiles)) * tile;
  return (corner + 1.0 + (octEncode(d) * 0.5 + 0.5) * inner) * texel;
}

// The irradiance at position p from the direction dir in rgb and the share
// of the sky in alpha, in a, and with pair set the same from the direction
// second in b. A non-zero view, the direction towards the viewer, moves the
// point off its surface along face and view and weighs the probes by the
// side of the surface that face faces.
void probeIrradiancePair(vec3 p, vec3 face, vec3 dir, vec3 second, vec3 view, bool pair, out vec4 a, out vec4 b) {
  float spacing = cb2.probeOrigin.w;
  bool surface = dot(view, view) > 0.0;
  vec3 at = surface
      ? p + (face * cb2.probeParams.z + view * cb2.probeParams.w) * spacing
      : p;
  ivec3 c = probeGrid();
  vec3 rel = (at - cb2.probeOrigin.xyz) / spacing;
  ivec3 base = clamp(ivec3(floor(rel)), ivec3(0), c - 2);
  vec3 alpha = clamp(rel - vec3(base), 0.0, 1.0);
  vec4 sumA = vec4(0.0), sumB = vec4(0.0);
  float total = 0.0;
  for (int i = 0; i < 8; i++) {
    ivec3 o = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
    ivec3 g = base + o;
    int index = g.x + c.x * (g.y + c.y * g.z);
    vec4 data = texelFetch(giProbes, index);
    if (data.w < 0.5) continue;
    vec3 probe = cb2.probeOrigin.xyz + vec3(g) * spacing + data.xyz;
    vec3 tri = mix(1.0 - alpha, alpha, vec3(o));
    float w = 1.0;
    if (surface) {
      float side = (dot(normalize(probe - p), face) + 1.0) * 0.5;
      w *= side * side + 0.2;
    }
    vec3 from = at - probe;
    float d = length(from);
    vec2 m = textureLod(sampler2D(giDistance, s5), probeTexel(index, from / max(d, 1e-4), 16.0, 14.0, cb2.atlas.zw), 0.0).rg;
    if (d > m.x) {
      // A floor on the variance softens the edges of the shadows that the
      // probes see. A wall in front of a probe still hides it.
      float soft = 0.15 * spacing;
      float variance = max(abs(m.y - m.x * m.x), soft * soft);
      float t = d - m.x;
      float chebyshev = variance / (variance + t * t);
      w *= max(chebyshev * chebyshev * chebyshev, 0.0);
    }
    w = max(w, 1e-6);
    // Weak weights fall faster, which hides light that leaks past them.
    if (w < 0.2) w *= w * w / 0.04;
    w *= tri.x * tri.y * tri.z;
    sumA += textureLod(sampler2D(giIrradiance, s5), probeTexel(index, dir, 8.0, 6.0, cb2.atlas.xy), 0.0) * w;
    if (pair) {
      sumB += textureLod(sampler2D(giIrradiance, s5), probeTexel(index, second, 8.0, 6.0, cb2.atlas.xy), 0.0) * w;
    }
    total += w;
  }
  a = total > 0.0 ? sumA / total : vec4(0.0);
  b = total > 0.0 ? sumB / total : vec4(0.0);
}

// The irradiance at p from the direction dir, as probeIrradiancePair gives
// it.
vec4 probeIrradiance(vec3 p, vec3 dir, vec3 view) {
  vec4 a, b;
  probeIrradiancePair(p, dir, dir, dir, view, false, a, b);
  return a;
}
