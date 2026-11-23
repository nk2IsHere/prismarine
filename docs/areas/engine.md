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

The native exports, the Dart names of flutter_gpu, the environment variables of the patches and the release and
archive names have prismarine forms since release prismarine1, such as `InternalFlutterGpu_PrismarineFeatures`,
`prismarineOldSpace` and `PRISMARINE_RENDERER`. The engine still reads `MCSM_RENDERER` when `PRISMARINE_RENDERER` is
not set. The patches of the releases before keep their names and the C++ names inside the engine keep their forms.
gpu_smoke numbers its check files by release, such as `lib/release_9.dart` and `lib/release_prismarine1.dart`.

## gpu_smoke

gpu_smoke draws through the `ScreenCopy` of `prismarine_scene` and reads the feature bits of the engine through its
own calls in `lib/engine_calls.dart`. It builds the shaders of the release 9 checks with the impellerc of the engine,
as [its README](../../tools/gpu_smoke/README.md) describes.

## Checks

gpu_smoke runs on each engine and platform after an engine change. Frames of an app must stay byte-identical on the
stock, the previous and the new engine. On Vulkan the validation layer must stay clean. The README lists the checks of
the current release.
