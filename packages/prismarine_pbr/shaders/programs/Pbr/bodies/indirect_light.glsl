// The indirect light of a surface from the probes, the sky and a
// reflection. It needs gi_probes.glsl, sky_read.glsl and the texture brdfLut
// with the sampler s1.

// The share of the specular light that ambient occlusion ao leaves.
float specularOcclusion(float nv, float ao, float roughness) {
  return clamp(pow(nv + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
}

// The diffuse and specular indirect light that leaves a surface at p with
// normal n towards v. The reflection has the reflected light in rgb and its
// weight in alpha.
void indirectTerms(vec3 p, vec3 n, vec3 v, vec3 base, float metallic, float roughness, float ao, vec4 reflection, out vec3 diffuse, out vec3 specular) {
  float nv = clamp(dot(n, v), 1e-4, 1.0);
  vec3 f0 = mix(vec3(0.04), base, metallic);
  vec2 ab = textureLod(sampler2D(brdfLut, s1), vec2(nv, roughness), 0.0).rg;
  vec3 scale = f0 * ab.x + ab.y;
  vec3 r = reflect(-v, n);
  vec3 irradiance, env;
  if (cb2.switches.y > 0.5) {
    irradiance = probeIrradiance(p, n, v).rgb;
    vec4 e = probeIrradiance(p, r, v);
    env = mix(e.rgb / PI, skySpecularRadiance(r, roughness), e.a);
  } else {
    irradiance = skyIrradianceOf(n);
    env = skySpecularRadiance(r, roughness);
  }
  diffuse = irradiance / PI * base * (1.0 - metallic) * (1.0 - scale) * ao;
  specular = mix(env, reflection.rgb, reflection.a) * scale * specularOcclusion(nv, ao, roughness);
  diffuse *= cb2.skyParams.y;
  specular *= cb2.skyParams.y;
}
