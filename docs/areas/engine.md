# The patched engine

prismarine has a patched Flutter engine. The patches cut the CPU cost of a Flutter GPU draw from about 0.9 µs to about
0.12 µs and add retained draws, multiple render targets, instancing, viewport arrays, compute, texel buffers, texture
arrays and 3D textures, texture views and more formats. They bring Impeller on Vulkan to the Linux and Windows
embedders and give the Dart VM collections at an idle point of the app and figures of its heap. An app runs on the
stock engine of Flutter too, only slower, with the same frames.

The engine has three parts.

| Part | Contents |
|---|---|
| `third_party/flutter_engine` | The engine patches, the Dart VM patches and the scripts that build, package and fetch a release. `RELEASE` gives the current release. |
| `third_party/flutter_gpu` | The Dart package of Flutter GPU with the patches that use the new exports. It falls back to the stock calls on the prebuilt engine. |
| `tools/gpu_smoke` | An app that checks the features of an engine on a platform and times its draws. |

[The engine README](../../third_party/flutter_engine/README.md) describes fetching, building, using and publishing
the engine and lists every patch. [The patch list of flutter_gpu](../../third_party/flutter_gpu/PATCHES.md) describes
the Dart side. An app depends on the patched flutter_gpu through `dependency_overrides` and builds on the engine with
the `--local-engine` flags of a release build.

## The engine directory

A machine has one engine directory, `PRISMARINE_ENGINE_DIR`, for every repository that builds on the engine. `fetch.sh`
unpacks each target into `<dir>/<target>` and `build.sh` keeps its sources and out dirs in `<dir>/flutter`. The
engine is data and is not in git. A repository that pins prismarine reads `RELEASE` and runs the scripts from its
pinned checkout.

## Names

The native exports, the feature bits, the environment variables of the patches, the release and archive names and the
patch markers of flutter_gpu still have the `Mcsm` and `mcsm` forms of the first releases. gpu_smoke calls the exports
in these forms and numbers its check files by release, such as `lib/release_9.dart`. The first engine release of
prismarine adds one patch that renames them, with flutter_gpu and gpu_smoke in lockstep and the feature bits unchanged.

## gpu_smoke and flutter_scene

gpu_smoke builds its shaders and reads the capabilities of the engine through the patched flutter_scene of the engine
fork, which prismarine does not carry. `tools/gpu_smoke/tool/scene.sh <checkout>` points the app at a checkout of it
with a `pubspec_overrides.yaml`. The dependency goes once the scene layer of prismarine replaces those parts.

## Checks

gpu_smoke runs on each engine and platform after an engine change. Frames of an app must stay byte-identical on the
stock, the previous and the new engine. On Vulkan the validation layer must stay clean. The README lists the checks of
the current release.
