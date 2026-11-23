# prismarine_scene

The package holds scene assets on Flutter. It is a Flutter package. `package:prismarine_scene/model.dart` holds the
model of a glTF without Flutter.

## glTF scenes

`GltfModel.read` reads the parts of a glTF that a renderer draws from a `GltfDocument` of
[prismarine_assets](assets.md). Its `draws` are the primitives of the default scene with their world matrices and
bounding spheres, its `materials` the metallic-roughness materials with their textures as image indices, its
`cameras` the perspective cameras and its `lights` the lights of `KHR_lights_punctual` with their places in the world.
`min` and `max` bound every draw. A primitive that is not a triangle list with 16-bit indices is left out and listed in
`skipped`.

`GpuScene.load` reads a glTF file and uploads each buffer view that a primitive reads as one device buffer. Its images
must be KTX2 files in RGBA8, as `prepareGltf` writes them. A texture is uploaded with every mip level on first use, in
an sRGB format when it is asked for so. `loadTextures` reads the files of some images off the UI thread ahead of their
first use.

## Files and paced loading

`FileAssetBundle` is an asset bundle that reads each key as an absolute file path. Pass it to a loader that reads
textures through an `AssetBundle` after their keys were made absolute. A read runs off the UI thread. A texture that is
not on disk is served as `staticBlackPng`, a 1×1 transparent black PNG. The bundle reports it once through
`FileAssetBundle.onMissing`, which prints the message by default.

`loadPace` lets a long scene load on the UI isolate give a waiting frame its turn. Call
`if (loadPace() case final p?) await p;` between the steps of the load. It returns null while the load has run less
than `loadTurn`, 4 ms, since the last turn. Otherwise it returns a future that completes after a zero timer. A
frame due meanwhile is drawn first. The common case stays synchronous.

## Checks

Run `flutter test` in `packages/prismarine_scene`.
