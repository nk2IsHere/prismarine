# gpu_smoke

gpu_smoke checks that Flutter GPU works with a given engine on a given desktop platform. The app renders a 4×4 texture
through the base `FullscreenVertex` and `CopyFragment` shaders of flutter_scene into a 64×64 target, waits for the GPU
and reads a pixel back. It times 2,000 draws with and without a texture bind per draw, prints `SMOKE` lines and exits
with 0 when the pixel matched.

Run it on each platform after a change to the engine. The engine, flutter_gpu and gpu_smoke are described on [the
area page of the engine](../../docs/areas/engine.md).

The app uses `third_party/flutter_gpu`. On the patched engine it runs the slot binds and leaf draws and on the prebuilt
engine of Flutter it runs the stock calls. The runners turn Flutter GPU on, with `FLTEnableFlutterGPU` on macOS,
`fl_dart_project_set_enable_flutter_gpu` and Impeller on Linux and `set_enable_flutter_gpu` on Windows.

The checks of each engine release are in `lib/`, one file per release, such as `lib/release_9.dart` for the checks of
release 9: a 64 KB uniform block, storage buffers in fragment shaders, array and 3D textures, rendering into an array
layer, texture views, the added formats as targets, a 2x MSAA D16 target read per sample, a compute pass with storage
buffers and images, indirect dispatches and draws and per-frame array uploads.

## Building and running

gpu_smoke needs the patched flutter_scene of the engine fork, which prismarine does not carry. Point the app at a
checkout of it once, then build it for the platform with the flags of the engine.

    tool/scene.sh <flutter_scene checkout>
    tool/features_bundle.sh [<engine out dir>/impellerc]
    flutter build <macos|linux|windows> --release \
      [--local-engine-src-path=<engine/src> --local-engine=<out> --local-engine-host=<out>]

`tool/features_bundle.sh` builds the shaders of the release 9 checks with the impellerc of the engine, by default
`$PRISMARINE_IMPELLERC`. The impellerc of the Flutter SDK refuses them.

On Windows, `windows_smoke.ps1 -EngineSrc <engine\src>` builds and runs the app on the stock engine and then on the
patched one. `Dockerfile.linux` is an image for a Linux build and a headless run under Xvfb and Mesa.

## Platforms

The app has runners for macOS, Linux and Windows. On the patched engine it draws with Metal on macOS and with Vulkan
on Linux and Windows. The results per platform are in [the engine
README](../../third_party/flutter_engine/README.md).
