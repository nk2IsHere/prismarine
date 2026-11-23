# prismarine_assets

The package reads, writes and checks the files of a game's assets in pure Dart. It reads glTF 2.0 files, builds them
as GLB and prepares them for the GPU, reads and writes textures as KTX2, writes images as PNG and decodes BC1 and BC3
blocks. It also cooks the geometry pools and the texture
arrays of a scene that `CookedScene` of [prismarine_frame](frame.md) describes. Every writer gives the same bytes on
every OS and CPU for the same input.

## glTF

`GltfBuilder` holds the JSON of a glTF and one binary buffer. You add buffer views and accessors, then meshes, nodes,
skins, animations and materials, and `toGlb` returns the GLB. `GltfBuilder.fromGlb` continues an existing GLB, such
as a mesh to which you add an animation. `readGlb` splits a GLB into its JSON and its binary chunk.

`validateGltf` checks the parts of the glTF 2.0 rules that viewers and importers fail on, such as an index past the
last vertex, a gap in the numbers of `TEXCOORD_n`, a normal that is not of unit length or a skinned mesh node with a
parent. It returns one line per problem and does not replace the Khronos validator. `mat4Compose`, `mat4Mul` and
`mat4InvertAffine` are the column-major matrix steps that a node hierarchy needs.

`GltfDocument.open` reads a `.gltf` file with its buffers from files or data URIs, or a `.glb` file. `floats` reads an
accessor as floats, with normalized integers scaled, and `uints` reads indices.

## Preparing a glTF for the GPU

`prepareGltf` writes a glTF as `scene.gltf`, `scene.bin` and `textures/<image>.ktx2` that a renderer loads without
work. Each triangle primitive becomes primitives with 16-bit indices and at most 65,535 vertices, split by
`splitChunks`. Each has one interleaved buffer view of position, normal, tangent and the first UV set, 48 bytes a
vertex. Missing normals come from `vertexNormals` and missing tangents from `vertexTangents`. Each image that a
material samples becomes RGBA8 KTX2 with every mip level, scaled down by halves to at most `textureSize`, 1024 by
default. A base colour or emissive image is sRGB and its mips are filtered in linear light. A normal map is
renormalized at each level. `mipChainRgba8` and `halveRgba8` are these filters. PNG and JPEG images are decoded with
`package:image`, several at a time in isolates. Nodes, materials, cameras and the lights of `KHR_lights_punctual` stay
as they were. The images have the media type `image/ktx2`, which is not part of core glTF 2.0.

## Textures and images

`encodeKtx2` writes a 2D texture, a texture array, a cube map or a volume texture with all its mip levels and a basic
data format descriptor. `Ktx2Format` lists the formats it writes, from `rgba8` to the BC1 and BC3 block formats with
their sRGB forms. `values` adds your own key-value data, such as the source of a texture.

`readKtx2` reads a KTX2 file of one of these formats without supercompression. `encodePng` writes RGBA8 pixels as a
PNG. `decodeBc1` and `decodeBc3` turn BC blocks into RGBA8, for a preview or for
a target without BC support.

## Geometry pools and texture arrays

A renderer that draws many meshes with few buffer binds needs the meshes of one vertex layout in one buffer.
`GeometryPools` collects them. `addVertices` appends the streams of a mesh to the pool of its layout and returns the
pool and the base vertex. `addIndices` appends an index list as 32-bit indices and returns its first index and its
count. `write` writes each pool as `pool_<i>.glb`, which a glTF viewer also opens. You decide which glTF mesh goes in
and how its streams are called, such as `UV0` for the first UV set.

`cookTextureArrays` groups the KTX2 textures of a directory by size, format and number of levels and writes each
group as one texture array. A layer holds the bytes of its texture file unchanged. The order of the layers and of the
arrays depends only on the stems, which keeps a cook reproducible.

The glTF files and KTX2 files carry the name of their writer, `prismarine_assets` by default. Pass `generator` or
`writer` to put the name of your own tool there.

## Checks

Run `dart test` in `packages/prismarine_assets`.
