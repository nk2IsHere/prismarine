# prismarine_scene

The package holds scene assets on Flutter. These are glTF scenes with their nodes, files and paced loading. It also
holds the GPU helpers of an app: a copy of a texture over the screen, a build hook for shader bundles and the backend
of the engine. It is a Flutter package. `package:prismarine_scene/model.dart` holds the model and the nodes of a glTF without Flutter.

## glTF scenes

`importSceneNodes` returns the roots of the default scene of a `GltfDocument` of [prismarine_assets](assets.md) as
`SceneNode` trees. A node has the name, the local transform and the indices of the mesh, camera, skin and
`KHR_lights_punctual` light of its glTF node, with its `extras`. A document without scenes gives each node that is no
child as a root. A node keeps its `world` transform and computes it again only after `setLocal` on it or on an
ancestor, or after `add` or `remove` moved it. `walk` visits a node and every node below it, parents first.

`GltfModel.read` reads the parts of a glTF that a renderer draws from a `GltfDocument`. Its `draws` are the primitives
of the nodes of the default scene with their world matrices and
bounding spheres, its `materials` the metallic-roughness materials with their textures as image indices, its
`cameras` the perspective cameras and its `lights` the lights of `KHR_lights_punctual` with their places in the world.
`min` and `max` bound every draw. A primitive that is not a triangle list with 16-bit indices is left out and listed in
`skipped`. Each primitive is also split into runs of at most `clusterTriangles` consecutive triangles, 4,096 by default,
with the box of each run in `clusters` and `clusterBounds`. A renderer can draw and cull a run on its own, as the point
light shadows of [prismarine_pbr](pbr.md) do. `sortTrianglesForRuns` sorts the triangles of each primitive along a
Morton curve through their centers in the buffers of a document. A run then covers a small part of its mesh. It leaves
primitives with a blending material in their order.

`GpuScene.load` reads a glTF file, sorts its triangles with `sortTrianglesForRuns` and uploads each buffer view that a
primitive reads as one device buffer. `clusterTriangles` sets the runs, and 0 keeps the order and one run per
primitive. Its images
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

## GPU helpers

`ScreenCopy` draws a texture over the whole render target. `ScreenCopy.load` loads its two shaders once from the
shader bundle of the package. `ScreenCopy.loaded` holds the copy afterwards. Its `pipeline` takes two triangles of
2D clip-space positions and its `source` slot takes the texture. The frame history of `prismarine_debug` takes this
form.

`package:prismarine_scene/build_hooks.dart` has `buildShaderBundle` for the `hook/build.dart` of a package that ships
shaders. It builds the bundle of a manifest, such as `screen_copy.shaderbundle.json`, into
`build/shaderbundles/<name>.shaderbundle` of the package. The package lists `build/shaderbundles/` as an asset and
keeps a `.gitignore` in it. The bundle keeps the backend of the target, Metal on macOS and Vulkan on Linux and Windows.
A vertex output whose name ends in `viewport_index` picks the viewport of a viewport array on Metal. On macOS each Metal
entry carries a library from the Metal compiler of Xcode, which the engine fork loads without a compile at run time.

`gpuBackend` reads the backend of Flutter GPU from the engine fork, `metal` or `vulkan`. `gpuFeatures` reads its
feature bits. `gpuBackend` is null and `gpuFeatures` is 0 on another engine.

`requireEngine(needs)` stops an app at its start when the running engine lacks a feature bit of `needs`, such as
`EngineFeatures.compute`. It throws an `EngineMismatch` with one message for the case that happened: the engine of
Flutter, a patched engine older than the release of this prismarine, or the missing features by name. Each message
gives the fix, `prismarine engine` and `prismarine build`. `engineProblem` returns the message without throwing.
`prismarineEngineRelease` is the release of `RELEASE`, which a test compares. The runner of `prismarine_render` does
not check the engine, since tests run it on the engine of the Flutter tester.

## Checks

Run `flutter test` in `packages/prismarine_scene`. A build of `tools/gpu_smoke` runs the build hook and draws with the
screen copy.
