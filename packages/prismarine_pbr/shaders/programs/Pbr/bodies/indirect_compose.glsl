// The indirect light that leaves a surface from its irradiance and the
// radiance of its environment. It needs the Indirect block and the texture
// brdfLut with the sampler s5.

// The share of the specular light that ambient occlusion ao leaves.
float specularOcclusion(float nv, float ao, float roughness) {
  return clamp(pow(nv + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
}

// The diffuse and specular indirect light that leaves a surface towards v
// from the parts of lightParts. The reflection has the reflected light in
// rgb and its weight in alpha.
void composeIndirect(vec3 n, vec3 v, vec3 base, float metallic, float roughness, float ao, vec4 reflection, vec3 irradiance, vec3 env, out vec3 diffuse, out vec3 specular) {
  float nv = clamp(dot(n, v), 1e-4, 1.0);
  vec3 f0 = mix(vec3(0.04), base, metallic);
  vec2 ab = textureLod(sampler2D(brdfLut, s5), vec2(nv, roughness), 0.0).rg;
  vec3 scale = f0 * ab.x + ab.y;
  diffuse = irradiance / PI * base * (1.0 - metallic) * (1.0 - scale) * ao;
  specular = mix(env, reflection.rgb, reflection.a) * scale * specularOcclusion(nv, ao, roughness);
  diffuse *= cb2.skyParams.y;
  specular *= cb2.skyParams.y;
}
