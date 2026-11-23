# prismarine_assets

The package writes and checks the files of a game's assets in pure Dart. It builds glTF 2.0 files as GLB, writes
textures as KTX2 and images as PNG and decodes BC1 and BC3 blocks. It also cooks the geometry pools and the texture
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

## Textures and images

`encodeKtx2` writes a 2D texture, a texture array, a cube map or a volume texture with all its mip levels and a basic
data format descriptor. `Ktx2Format` lists the formats it writes, from `rgba8` to the BC1 and BC3 block formats with
their sRGB forms. `values` adds your own key-value data, such as the source of a texture.

`encodePng` writes RGBA8 pixels as a PNG. `decodeBc1` and `decodeBc3` turn BC blocks into RGBA8, for a preview or for
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
