// The reads of the sky maps. It needs the Indirect and Frame blocks and the
// textures skyEnv, skySpecular and skyIrradiance with a sampler s6 that
// wraps u and clamps v.

// The radiance of the sky towards d at mip lod of skyEnv.
vec3 skyRadiance(vec3 d, float lod) {
  if (cb2.switches.x < 0.5) {
    return mix(cb0.groundColor.rgb, cb0.skyColor.rgb, clamp(d.y * 0.5 + 0.5, 0.0, 1.0));
  }
  return textureLod(sampler2D(skyEnv, s6), equirect(d), lod).rgb * cb2.skyParams.x;
}

// The sky's radiance towards d filtered for the roughness r.
vec3 skySpecularRadiance(vec3 d, float r) {
  if (cb2.switches.x < 0.5) return skyRadiance(d, 0.0);
  return textureLod(sampler2D(skySpecular, s6), equirect(d), r * cb2.skyParams.z).rgb * cb2.skyParams.x;
}

// The irradiance of the sky on a surface with normal n, without occlusion.
vec3 skyIrradianceOf(vec3 n) {
  if (cb2.switches.x < 0.5) return skyRadiance(n, 0.0) * PI;
  return textureLod(sampler2D(skyIrradiance, s6), equirect(n), 0.0).rgb * cb2.skyParams.x;
}
