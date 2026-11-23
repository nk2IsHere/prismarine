// The indirect light of a surface from the probes, the sky and a
// reflection. It needs gi_probes.glsl, sky_read.glsl and the texture brdfLut
// with the sampler s5.
#include "Pbr/bodies/indirect_compose.glsl"

// The irradiance at a surface at p with shading normal n and face normal
// face, seen from v, and the radiance that reaches it from the reflected
// direction, filtered for the roughness. Both come from the probes and the
// sky.
void lightParts(vec3 p, vec3 n, vec3 face, vec3 v, float roughness, out vec3 irradiance, out vec3 env) {
  vec3 r = reflect(-v, n);
  if (cb2.switches.y > 0.5) {
    vec4 en, er;
    probeIrradiancePair(p, face, n, r, v, true, en, er);
    irradiance = en.rgb;
    env = mix(er.rgb / PI, skySpecularRadiance(r, roughness), er.a);
  } else {
    irradiance = skyIrradianceOf(n);
    env = skySpecularRadiance(r, roughness);
  }
}

// The indirect light of a surface at p with lightParts and composeIndirect.
void indirectTerms(vec3 p, vec3 n, vec3 face, vec3 v, vec3 base, float metallic, float roughness, float ao, vec4 reflection, out vec3 diffuse, out vec3 specular) {
  vec3 irradiance, env;
  lightParts(p, n, face, v, roughness, irradiance, env);
  composeIndirect(n, v, base, metallic, roughness, ao, reflection, irradiance, env, diffuse, specular);
}
