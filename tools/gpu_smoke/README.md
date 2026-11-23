# gpu_smoke

Does Flutter GPU work with a given engine on a given desktop platform? The app
renders a 4×4 texture through flutter_scene's base `FullscreenVertex` +
`CopyFragment` into a 64×64 target, waits for the GPU, reads a pixel back,
times 2,000 draws (with and without a texture bind per draw), prints `SMOKE`
lines and exits (0 = the pixel matched).

It uses the vendored `third_party/flutter_gpu`, so on the patched engine
(third_party/flutter_engine) it runs the slot binds and leaf draws, and on
Flutter's prebuilt engine the stock calls. The runners enable Flutter GPU
(macOS `FLTEnableFlutterGPU`, Linux `fl_dart_project_set_enable_flutter_gpu` +
Impeller, Windows `set_enable_flutter_gpu`).

    flutter build <macos|linux|windows> --release \
      [--local-engine-src-path=<engine/src> --local-engine=<out> --local-engine-host=<out>]

On the mcsm9 engine it also checks S2's additions (`lib/mcsm9.dart`: a 64 KB
uniform block, storage buffers in fragment shaders, array and 3D textures,
rendering into an array layer, texture views, the added formats as targets, a
2x MSAA D16 target read per sample, a compute pass with storage buffers and
images, indirect dispatches and draws, per-frame array uploads). Their
shaders need the engine's impellerc, so build them first:

    tool/s2_bundle.sh [<engine out dir>/impellerc]   # default $MCSM_IMPELLERC

Results per platform: third_party/flutter_engine/README.md.
