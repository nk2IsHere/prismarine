#version 460
#ifdef IMPELLER_TARGET_VULKAN
// Vulkan: SPIR-V's SignedZeroInfNanPreserve for 32-bit floats (float
// controls), or drivers may fold NaN, Inf and -0 away.
#extension GL_EXT_spirv_intrinsics : require
spirv_execution_mode(extensions = ["SPV_KHR_float_controls"],
                     capabilities = [4466], 4461, 32);
#endif
// IEEE arithmetic survives: NaN and Inf, and -0 + 0 = +0 (fast math may
// drop the addition and keep -0): green when it does.
uniform Zero {
  vec4 zero;
} zero;

out vec4 frag_color;

void main() {
  float nan_value = sqrt(zero.zero.x - 1.0);
  float inf_value = 1.0 / zero.zero.x;
  float negative_zero = zero.zero.x * -1.0;
  bool ok = isnan(nan_value) && isinf(inf_value) &&
            1.0 / (negative_zero + 0.0) > 0.0;
  frag_color = ok ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
