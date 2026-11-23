import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_frame/prismarine_frame.dart';

/// The engine format for a DXGI-style format name as the exe's targets and
/// views name them (RenderDoc's spelling: `R11G11B10_FLOAT`,
/// `D32_SFLOAT_S8_UINT`, `BC1_SRGB`, …), or for a slice texture's
/// `rawFormat` (`dxt1`, `rgba8`, …; formats/s2/shaders.md "Surface formats
/// to DXGI").
gpu.PixelFormat pixelFormat(String name, {bool srgb = false}) {
  final n = name.toUpperCase();
  return switch (n) {
    'R11G11B10_FLOAT' || 'B10G11R11_UFLOAT_PACK32' => .r11g11b10UFloat,
    'R8G8B8A8_UNORM' ||
    'RGBA8' => srgb ? .r8g8b8a8UNormIntSRGB : .r8g8b8a8UNormInt,
    'R8G8B8A8_SRGB' || 'R8G8B8A8_UNORM_SRGB' => .r8g8b8a8UNormIntSRGB,
    'B8G8R8A8_UNORM' ||
    'ARGB8' => srgb ? .b8g8r8a8UNormIntSRGB : .b8g8r8a8UNormInt,
    'B8G8R8A8_SRGB' => .b8g8r8a8UNormIntSRGB,
    'R16G16B16A16_FLOAT' ||
    'R16G16B16A16_SFLOAT' ||
    'RGBA16F' => .r16g16b16a16Float,
    'R16G16B16A16_UNORM' => .r16g16b16a16UNormInt,
    'R32_FLOAT' || 'R32_SFLOAT' => .r32Float,
    'R32G32_FLOAT' => .r32g32Float,
    'R32G32B32A32_FLOAT' || 'R32G32B32A32_SFLOAT' => .r32g32b32a32Float,
    'R32_UINT' || 'UNKNOWN32' => .r32UInt,
    'R32G32B32A32_UINT' => .r32g32b32a32UInt,
    'R16_FLOAT' => .r16Float,
    'R16G16_FLOAT' => .r16g16Float,
    'R8_UNORM' || 'L8' => .r8UNormInt,
    'A8' || 'A8_UNORM' => .a8UNormInt,
    'R8G8_UNORM' || 'RG8' => .r8g8UNormInt,
    'D16_UNORM' || 'D16' => .d16UNormInt,
    'D32_FLOAT' || 'D32_SFLOAT' || 'D32' => .d32Float,
    'D32_SFLOAT_S8_UINT' ||
    'D32S8' ||
    'D32_FLOAT_S8X24_UINT' => .d32FloatS8UInt,
    // Apple GPUs have no 24-bit depth; the exe's D24S8 is only its back
    // buffer's depth, which no pass reads.
    'D24_UNORM_S8_UINT' || 'D24S8' => .d32FloatS8UInt,
    'BC1_UNORM' || 'DXT1' => srgb ? .bc1RGBAUNormIntSRGB : .bc1RGBAUNormInt,
    'BC1_SRGB' || 'BC1_UNORM_SRGB' => .bc1RGBAUNormIntSRGB,
    'BC3_UNORM' || 'DXT5' => srgb ? .bc3RGBAUNormIntSRGB : .bc3RGBAUNormInt,
    'BC3_SRGB' || 'BC3_UNORM_SRGB' => .bc3RGBAUNormIntSRGB,
    _ => throw UnsupportedError('S2 format $name'),
  };
}

/// Bytes of one texel (or one 4×4 block) of [f], for uploads.
int texelBytes(gpu.PixelFormat f) => switch (f) {
  .r8UNormInt || .a8UNormInt => 1,
  .r8g8UNormInt || .r16Float || .d16UNormInt => 2,
  .d32FloatS8UInt => 4,
  .r16g16b16a16Float || .r16g16b16a16UNormInt || .r32g32Float => 8,
  .r32g32b32a32Float || .r32g32b32a32UInt => 16,
  .bc1RGBAUNormInt || .bc1RGBAUNormIntSRGB => 8,
  .bc3RGBAUNormInt || .bc3RGBAUNormIntSRGB => 16,
  _ => 4,
};

bool isDepth(gpu.PixelFormat f) =>
    f == gpu.PixelFormat.d16UNormInt ||
    f == gpu.PixelFormat.d32Float ||
    f == gpu.PixelFormat.d32FloatS8UInt ||
    f == gpu.PixelFormat.d24UnormS8Uint;

gpu.SamplerAddressMode _address(String a) => switch (a.toLowerCase()) {
  'wrap' || 'repeat' => .repeat,
  'mirror' || 'mirrorrepeat' => .mirror,
  'border' || 'clampborder' => .clampToBorder,
  'mirroronce' || 'mirrorclamp' => .mirrorClampToEdge,
  _ => .clampToEdge,
};

gpu.CompareFunction compareFunction(String c) => switch (c.toLowerCase()) {
  'never' => .never,
  'always' || 'alwaystrue' => .always,
  'less' => .less,
  'equal' => .equal,
  'lessequal' => .lessEqual,
  'greater' => .greater,
  'notequal' => .notEqual,
  'greaterequal' => .greaterEqual,
  _ => throw UnsupportedError('compare $c'),
};

/// A Direct3D 11 stencil operation by the plan's name.
gpu.StencilOperation stencilOp(String op) => switch (op.toLowerCase()) {
  'keep' => .keep,
  'zero' => .zero,
  'replace' => .setToReferenceValue,
  'incrsat' => .incrementClamp,
  'decrsat' => .decrementClamp,
  'invert' => .invert,
  'incr' => .incrementWrap,
  'decr' => .decrementWrap,
  _ => throw UnsupportedError('stencil op $op'),
};

/// A plan's stencil test as the engine's config, both faces alike.
gpu.StencilConfig stencilConfigOf(Stencil s) => gpu.StencilConfig(
  compareFunction: compareFunction(s.func),
  depthStencilPassOperation: stencilOp(s.passOp),
  readMask: s.readMask,
  writeMask: s.writeMask,
);

/// The engine's stencil config for draws without a test: always passes and
/// keeps the stored value.
final noStencil = gpu.StencilConfig();

/// A Direct3D 11 sampler state as the engine's whole sampler.
gpu.McsmSampler sampler(SamplerState s) => gpu.McsmSampler(
  minFilter: s.minLinear ? .linear : .nearest,
  magFilter: s.magLinear ? .linear : .nearest,
  mipFilter: s.mipLinear ? .linear : .nearest,
  widthAddressMode: _address(s.address[0]),
  heightAddressMode: _address(s.address[1]),
  depthAddressMode: _address(s.address.length > 2 ? s.address[2] : 'clamp'),
  maxAnisotropy: s.anisotropy < 1 ? 1 : s.anisotropy,
  compare: s.compare == null ? null : compareFunction(s.compare!),
  borderColor: switch (s.border) {
    'opaqueBlack' => .opaqueBlack,
    'opaqueWhite' => .opaqueWhite,
    _ => .transparentBlack,
  },
  minLod: s.minLod,
  maxLod: s.maxLod,
  lodBias: s.lodBias,
);

gpu.BlendFactor blendFactor(String f) => switch (f.toLowerCase()) {
  'zero' => .zero,
  'one' => .one,
  'srccolor' || 'sourcecolor' => .sourceColor,
  'invsrccolor' ||
  'oneminussrccolor' ||
  'oneminussourcecolor' => .oneMinusSourceColor,
  'srcalpha' || 'sourcealpha' => .sourceAlpha,
  'invsrcalpha' ||
  'oneminussrcalpha' ||
  'oneminussourcealpha' => .oneMinusSourceAlpha,
  'dstcolor' || 'destinationcolor' => .destinationColor,
  'invdstcolor' || 'oneminusdstcolor' => .oneMinusDestinationColor,
  'dstalpha' || 'destinationalpha' => .destinationAlpha,
  'invdstalpha' || 'oneminusdstalpha' => .oneMinusDestinationAlpha,
  'srcalphasat' || 'srcalphasaturate' => .sourceAlphaSaturated,
  'factorcolor' || 'blendcolor' || 'constantcolor' => .blendColor,
  _ => throw UnsupportedError('blend factor $f'),
};

gpu.BlendOperation blendOp(String o) => switch (o.toLowerCase()) {
  'add' => .add,
  'subtract' => .subtract,
  'reversesubtract' || 'revsubtract' => .reverseSubtract,
  _ => throw UnsupportedError('blend operation $o'),
};

gpu.CullMode cullMode(String c) => switch (c.toLowerCase()) {
  'none' || 'nocull' => .none,
  'front' => .frontFace,
  _ => .backFace,
};

/// [b] with its write mask folded into the blend: flutter_gpu has no colour
/// write mask (the spec's engine gaps), so a masked-out half (RGB or alpha)
/// blends as (zero, one, add), which keeps the target's value exactly. A
/// mask that splits the colour channels (rare: none in the treasure room)
/// keeps all three.
Blend maskedBlend(Blend b) {
  final m = b.writeMask;
  if (m == 0xf) return b;
  const keep = ['zero', 'one', 'add'];
  final rgb = m & 7 != 0;
  final alpha = m & 8 != 0;
  final colour = !rgb
      ? keep
      : (b.enabled ? b.color : const ['one', 'zero', 'add']);
  final alphaOps = !alpha
      ? keep
      : (b.enabled ? b.alpha : const ['one', 'zero', 'add']);
  return Blend(enabled: true, color: colour, alpha: alphaOps, writeMask: 0xf);
}

/// The vertex format of a buffer-fed input in its DXGI name (the skinned
/// streams: float3 positions, signed normalized byte normals and tangents).
gpu.VertexFormat streamFormat(String format) => switch (format) {
  'R32G32B32A32_FLOAT' => gpu.VertexFormat.float32x4,
  'R32G32B32_FLOAT' => gpu.VertexFormat.float32x3,
  'R32G32_FLOAT' => gpu.VertexFormat.float32x2,
  'R32_FLOAT' => gpu.VertexFormat.float32,
  'R8G8B8A8_SNORM' => gpu.VertexFormat.snorm8x4,
  'R8G8B8A8_UNORM' => gpu.VertexFormat.unorm8x4,
  'R8G8B8A8_UINT' => gpu.VertexFormat.uint8x4,
  'R16G16_SNORM' => gpu.VertexFormat.snorm16x2,
  'R16G16B16A16_SNORM' => gpu.VertexFormat.snorm16x4,
  _ => throw UnsupportedError('S2 stream format $format'),
};
