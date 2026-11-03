# The Flutter engine, patched for mcsm

mcsm draws through Flutter GPU, and on the stock Flutter engine every draw costs about 0.9 µs of CPU before our own code runs. The patches here cut that to ~0.12 µs on Macs (TownFair's paint −1.7 ms a frame). They also load our Metal shaders precompiled (a fresh build's first scene no longer stalls ~3 s) and cache ANGLE's compiled programs on Windows. Since mcsm6 a render pass may mix target formats (the shadow occlusion buffer is RGBA8 as the exe's) and release builds take the Dart new generation's size (fewer stop-the-world scavenges). Since mcsm8 Windows and Linux run Impeller on **Vulkan** (GLES stays as the fallback and behind a switch): see [Vulkan on Windows and Linux](#vulkan-on-windows-and-linux-mcsm8).

**The patched engine is optional.** Everything builds and runs on Flutter's stock engine too, only slower, and the frames are byte-identical either way. The patches apply to the engine of the project's Flutter (3.47.7 stable, engine revision `deb287481e3ce9468f3434937ced4240a70539ca`). They live here as reviewable files; the downloaded or built engine is data (`$MCSM_DATA/engine`, gitignored).

**Where it's useful today:** the game player (`apps/mcsm_player`) on macOS, Linux and Windows: each play script (`tool/play.sh`, `tool/linux/play.sh`, `tool/windows/play.ps1`) builds on it when it is there. `tools/gpu_smoke` runs on it too.

Contents:
- [Get the engine: download it](#download-it-a-minute)
- [Or build it yourself](#or-build-it-yourself): [macOS](#macos-arm64-and-x86_64), [Linux](#linux-x64-native-and-arm64-cross-built), [Windows](#windows-x64-native-and-arm64-cross-built)
- [Use it](#use-it)
- [Publish a new build](#publish-a-new-build-maintainers)
- [Vulkan on Windows and Linux](#vulkan-on-windows-and-linux-mcsm8)
- [Patches](#patches)
- [Reference](#reference-targets-backends-test-results-2026-10-17)

## Download it (a minute)

The repo's GitHub release `engine-deb287481e3c-mcsm6` (tag in `RELEASE`) holds the engine for six targets, 14–21 MB each. Each archive contains only what a release `flutter build … --local-engine` reads.

| Target | Archive | Out dir (`--local-engine`) |
|---|---|---|
| macOS arm64 | `mcsm-engine-macos-arm64.tar.xz` | `host_release_arm64` |
| macOS Intel | `mcsm-engine-macos-x64.tar.xz` | `host_release` |
| Linux x64 | `mcsm-engine-linux-x64.tar.xz` | `host_release` |
| Linux arm64 (for arm64 Linux machines) | `mcsm-engine-linux-arm64.tar.xz` | `linux_release_arm64` |
| Windows x64 | `mcsm-engine-windows-x64.tar.xz` | `host_release` |
| Windows arm64 (for arm64 Windows machines) | `mcsm-engine-windows-arm64.tar.xz` | `host_release_arm64` |

**You need** the GitHub CLI (`gh`), logged in (`gh auth login`) to an account that can read the repo. The release is on the private repo.

macOS or Linux, from the repo root:

    third_party/flutter_engine/fetch.sh            # this machine's target
    third_party/flutter_engine/fetch.sh macos-x64  # or another one

Windows (PowerShell, from the repo root):

    powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\fetch.ps1

The scripts:
1. download the archive and its `.sha256`, and check it;
2. unpack it to `$MCSM_DATA/engine/<target>/` (default `data/engine/<target>/`);
3. link the engine's `dart-sdk` to your Flutter SDK's (the same Dart).

On macOS, `play.sh` picks the engine up by itself. Elsewhere the scripts print the `flutter build` flags.
- **Offline:** download the archive and its `.sha256` from the release page by hand, then set `MCSM_ENGINE_ARCHIVE=<file>` (or pass `fetch.ps1 -Archive <file>`).
- **Verified (mcsm6):** the macOS arm64, macOS x86_64, Linux x64 and Windows x64 archives, fetched from the file, build a player whose treehouse D1 capture (frames, events, audio) is byte-identical to the stock engine's on the same OS (see the mcsm6 results below). The arm64 Linux and Windows archives were built but not run (no arm64 machine).

## Or build it yourself

Each build checks out Flutter at the engine revision, applies `patches/*.patch`, fetches the engine's dependencies with Chromium's `gclient` (depot_tools; the scripts install it), and builds only the release targets the Flutter tool reads. Plan on several GB of disk and an hour or so per machine. The Flutter SDK you build the app with must be the project's 3.47.7 (`data/flutter`, or `MCSM_FLUTTER`).

### macOS (arm64 and x86_64)

**You need:**
- Xcode (27 tested), with its command-line tools;
- the Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` (~0.8 GB; Xcode 27 ships without `metal`, and the engine's own shaders need it);
- ~20 GB free: 13 GB of sources in `$MCSM_DATA/engine/flutter` (a `--shared` clone of `data/flutter`) plus 2.6–4.6 GB per out dir.

**Build:**

    third_party/flutter_engine/build.sh all                      # arm64: out/host_release_arm64
    MCSM_ENGINE_CPU=x64 third_party/flutter_engine/build.sh build  # Intel: out/host_release

- `all` = `setup` (depot_tools, clone, `gclient sync`, 20–40 min of downloads) + `patch` + `build`.
- **Time:** the first arm64 build took ~1 h on an M2 Pro (6 jobs; `MCSM_ENGINE_JOBS`). x64 took 13 min more with the sources already built.
- **Rebuilds:** after a patch edit, run `build.sh patch` then `build.sh build` (minutes).
- **Disk:** `MCSM_ENGINE_TRIM=1` deletes the out dir's object files afterwards (~2 GB), at the price of a full rebuild next time.
- **Using it:** `play.sh` uses the result by itself (see [Use it](#use-it)).
- **After an Xcode update:** the out dir rebuilds in full, and two things need redoing first: the Metal Toolchain download (`xcodebuild -downloadComponent MetalToolchain`), and the SDK link in `engine/src/flutter/prebuilts/SDKs` (`gclient sync` made `MacOSX<version>.sdk` pointing into Xcode; when Xcode's SDK version changes, point a link named after the new version at it and delete the old one, or the compiler finds no sysroot).

### Linux (x64 native, and arm64 cross-built)

**You need** an x86_64 Linux machine (Ubuntu 24.04/26.04 tested) with:
- `git`, `python3`, `curl`, `xz-utils`, `pkg-config` (`gclient` brings the compiler and the Debian sysroots for both CPUs);
- ~30 GB free: ~11 GB of sources, ~1 GB per release out dir, 5.4 GB for the optional test build;
- ~10 min (x64) + ~13 min (arm64) on 16 cores after the download.

**Build:**

    export MCSM_ENGINE_DIR=$HOME/mcsm-engine
    third_party/flutter_engine/linux.sh setup   # depot_tools, clone, patches, gclient sync
    third_party/flutter_engine/linux.sh build   # out/host_release (x64), out/linux_release_arm64 (arm64)
    third_party/flutter_engine/linux.sh test    # optional: the gpu_unittests our patches touch

**The impeller tests** (Vulkan on SwiftShader, optional) need a display. In Docker with `tools/gpu_smoke/Dockerfile.linux` (Ubuntu + GTK + Xvfb + Mesa), with `O=$MCSM_ENGINE_DIR/flutter/engine/src/out/host_debug_unopt_tests`, run
`VK_ICD_FILENAMES=$O/vk_swiftshader_icd.json VK_LAYER_PATH=$O/vulkan-data VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation LD_LIBRARY_PATH=$O xvfb-run -a -s "-screen 0 1280x800x24 -extension MIT-SHM" $O/impeller_unittests "--gtest_filter=*/Vulkan:-*Playground*"`.
Result: 711 passed, 21 skipped.

**To build Flutter apps for Linux** you also need Flutter's usual Linux desktop packages: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`. `tools/gpu_smoke/Dockerfile.linux` installs them.

### Windows (x64 native, and arm64 cross-built)

**You need:**
- Windows 10/11 x64.
- ~30 GB free: ~10 GB of sources, 2.5 GB (x64) and 3.6 GB (arm64) out dirs, plus the tools.
- An elevated PowerShell. Long builds should run where closing a terminal or an SSH session won't stop them, for example a scheduled task.
- **The tools:** `third_party\flutter_engine\windows-toolchain.ps1` installs them all (Git, Python 3.12, VS Build Tools, the Debugging Tools, long paths):
  - Git and Python 3.12 (winget);
  - Visual Studio 2022 Build Tools, with:
    - `Microsoft.VisualStudio.Workload.VCTools`;
    - `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` and `…VC.Tools.ARM64`;
    - `…VC.ATL` and `…VC.ATL.ARM64`;
    - `Microsoft.VisualStudio.Component.Windows11SDK.22621`;
  - the Windows SDK 10.0.22621's Debugging Tools for Windows (winget `Microsoft.WindowsSDK.10.0.22621`, feature `OptionId.WindowsDesktopDebuggers`);
  - long paths: `LongPathsEnabled=1` and `git config --system core.longpaths true`.

**Build:**

    powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\windows-toolchain.ps1
    powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\windows.ps1 -EngineDir C:\mcsm-engine

- `windows.ps1` builds `out\host_release` (x64) and `out\host_release_arm64` (arm64, cross-built). `-Cpu x64|arm64|both` picks which; logs go to `<EngineDir>\logs`.
- **Time:** ~25 min (x64) and ~35 min (arm64) on 10–12 cores, after a ~30 min download.
- **The arm64 engine** is for arm64 Windows machines: its `gen_snapshot.exe` is an arm64 program. The Flutter tool builds a Windows app only for the machine's own CPU.

## Use it

**macOS: `play.sh` uses the patched engine by default** when one is there. `tools/toolchain/env.sh` looks for it in this order:
1. `$MCSM_DATA/engine/macos-arm64/src`, or `…/macos-x64/src` on an Intel Mac (fetched);
2. `$MCSM_DATA/engine/flutter/engine/src` (built by `build.sh`).

Otherwise it uses Flutter's stock engine. `play.sh` prints which one it builds on: `mcsm: building on the patched engine host_release_arm64 (…)`. In `.env`:
- `MCSM_LOCAL_ENGINE=off` (or empty) always uses the stock engine;
- `MCSM_LOCAL_ENGINE=<path to an engine/src>` uses that engine;
- `MCSM_LOCAL_ENGINE_NAME=host_release` picks the x86_64 out dir (the default is `host_release_arm64` on an arm64 Mac, `host_release` on an Intel one).

What else to know on macOS:
- Debug builds (`flutter run`) always use the stock engine. Profile builds (`profile.sh`) use a self-built profile engine when there is one (`MCSM_ENGINE_MODE=profile build.sh build` → `out/host_profile_arm64`; it takes `--no-inline-alloc` and `--profile_vm` through `MCSM_DART_FLAGS`), else the stock one.
- An app built on the patched engine is for one CPU only: the Flutter tool sets `ARCHS` from the engine's name.
- **Universal app** (to share it): build once per engine and copy each `.app` aside, then run `apps/mcsm_player/tool/universal_app.sh <arm64.app> <x86_64.app> <out.app>`.
- The patched and stock engines can take turns in one build dir; the Flutter tool rebuilds what changed.

**What mcsm6 changes in the player** (any OS; an older engine or Flutter's own simply doesn't have it):
- **Dart's new generation.** The runners (`macos/Runner/MainFlutterWindow.swift`, `linux/runner/main.cc`, `windows/runner/main.cpp`) set `--new_gen_semi_max_size` before the engine starts: the default below, `--new-gen=<MB>` for another (0: the VM's own 16 MB), `MCSM_DART_FLAGS=<flags,…>` adds flags (e.g. `--verbose_gc`, which prints each collection to stderr). A `FLUTTER_ENGINE_SWITCHES` already in the environment wins (`tool/profile.sh`).
- **Mixed target formats** (macOS/Metal): the occlusion buffer is RGBA8 with the depth in R32F targets, as the exe has them (mcsm_look_scene `shadows.dart`). Frames are byte-identical to the stock engine's.
- `MCSM_ENGINE_FEATURES=0` (a bit mask, flutter_scene P23) makes the Dart code take the paths it takes on other engines, in the same build: for A/B runs.

**Linux and Windows:** `apps/mcsm_player/tool/linux/play.sh` and `tool/windows/play.ps1` find a fetched or built engine as `play.sh` does on macOS (`MCSM_LOCAL_ENGINE`, `MCSM_LOCAL_ENGINE_NAME`). By hand, pass the flags to `flutter build`:

    flutter build linux   --release --local-engine-src-path=<…>/engine/src --local-engine=host_release --local-engine-host=host_release
    flutter build windows --release --local-engine-src-path=<…>\engine\src --local-engine=host_release --local-engine-host=host_release

- **`<…>/engine/src`** is `$MCSM_DATA/engine/<target>/src` for a fetched engine, or `<MCSM_ENGINE_DIR or EngineDir>/flutter/engine/src` for a built one.
- **Arm64 machines:** use `linux_release_arm64` or `host_release_arm64` for both flags.
- **A self-built out dir** needs the `flutter_patched_sdk_product` link; the build scripts make it.
- **Try it with `tools/gpu_smoke`:** `flutter build <os>` it with those flags and run it. It prints `SMOKE` lines with the per-draw times. On Windows, `tools\gpu_smoke\windows_smoke.ps1 -EngineSrc <…>\engine\src` builds and runs it on the stock engine and then the patched one.

## Vulkan on Windows and Linux (mcsm8)

Flutter's Windows and Linux embedders draw with ANGLE/GLES and GL only; patches 0013–0018 give both an Impeller Vulkan path, used by default where the machine has a working Vulkan device:
- **Windows:** our own instance and device (`vulkan-1.dll`), a swapchain per view on its window, ANGLE when there's no usable device. `MCSM_RENDERER=gles` forces ANGLE.
- **Linux (GTK):** our own instance and device (`libvulkan.so.1`); each frame's layer reaches GTK's GL context without a copy through the CPU (`VK_KHR_external_memory_fd` / `GL_EXT_memory_object_fd`, with semaphores), else through a read-back. `MCSM_RENDERER=gles` (or `FLUTTER_LINUX_RENDERER=opengl`) forces GL; `software` is Flutter's software renderer.
- The engine logs the choice once (`renderer: Vulkan <device> (api …, driver …, multiViewport, vertex viewport index)` or `renderer: ANGLE/GLES (…why…)`), and the player logs `renderer: vulkan|gles|metal, engine features …`.
- Impeller keeps its Vulkan pipeline cache in `%LOCALAPPDATA%\<exe>\flutter_vk_cache` or `~/.cache/<exe>/flutter_vk_cache` (`FLUTTER_VK_CACHE_DIR=<dir>`, `0` turns it off).
- Feature bits (`InternalFlutterGpu_McsmFeatures`, bit 1024 = the bits are the running backend's): Vulkan has 1, 2, 4, 8, 64, 512 and 256 (viewport arrays) where the device has `multiViewport` and a vertex-stage viewport index; GLES 1, 2, 4, 8, 64, 128, 512; Metal 1, 2, 4, 8, 16, 64, 256, 512.
- **Results** (2026-10-26): the treehouse D1 capture's events and audio are bit-identical between Vulkan, GLES (Linux, Windows) and Metal; Vulkan vs GLES frames differ by GPU rounding only (UHD 620: 531 px over 16 levels in a 1280×720 frame, none of it a missing pass; Linux: under 25 px over 4 levels). gpu_smoke passes on Vulkan on the RTX 4060 Ti, lavapipe and the UHD 620, and the Khronos validation layer reports nothing for gpu_smoke and the player. TownFairHall on the RTX: 17.6 ms a frame on Vulkan vs 28.8 on GLES (p50); the treehouse holds 60 fps on both.
- **Known limit of the GLES fallback:** on ANGLE (WARP and the UHD 620) a Flutter GPU texture read back from the UI thread right after its command buffer completes can come back empty; it happens on the stock engine too and doesn't reach the screen (the tablet's GLES frames match its Vulkan ones). gpu_smoke re-reads once before it counts a read as wrong.

## Publish a new build (maintainers)

1. Bump `RELEASE` (e.g. `engine-<engine revision, 12 chars>-mcsm<patch count>`).
2. Package each target where it was built:
   - macOS and Linux: `package.sh <engine/src> <out dir> <target> <dest> [<host out dir>]`;
   - Windows: `package.ps1 -Src … -Out … -Target … -Dest … [-HostOut …]`.
   
   Each makes `mcsm-engine-<target>.tar.xz` and `.sha256`. `package.sh` records `MCSM_ENGINE_REV` (default `deb287481e3c…`).
3. Check each archive the way users get it: `fetch.sh` with `MCSM_ENGINE_ARCHIVE=<file>`, or `fetch.ps1 -Archive <file>`, into a scratch `MCSM_DATA`, then build the player or gpu_smoke from it.
4. Run `gh release create <tag> -R "$MCSM_ENGINE_REPO" --title … --notes-file … mcsm-engine-* SHA256SUMS`. An asset must be under 2 GiB; ours are ~20 MB.

## Patches

- `0001-mac-link-with-xcode-ld.patch`: `build/config/mac/BUILD.gn` links with Xcode's own `ld`. The engine's bundled clang links with lld, which can't parse the macOS 27 SDK's `.tbd` files: they list `arm64e.x1-macos` targets ("unknown architecture"). Build-only; the binaries are the same code.
- `0002-gpu-pipeline-cache-retained-bindings.patch` (E1+E2, `lib/gpu/render_pass.{h,cc}`):
  - **E1:** each draw used to copy, hash and look up a full pipeline descriptor, with two string-keyed shader-function lookups. Now a pass caches the Impeller pipeline per (RenderPipeline, pipeline state). A version counter, bumped by the nine state-setting exports, makes the common case one compare.
  - **E2, Metal only:** each bound resource used to be re-sent at every draw with a fresh `ShaderMetadata` copy (TtMesh's block: 40 member names), which `RenderPassMTL` never reads. Now bindings go by metadata pointer. Only the bindings and vertex buffers the encoder doesn't already hold from the same entry are sent; a per-index "last writer" check keeps the old semantics when two entries share an index. GLES and Vulkan keep the old path.
- `0003-gpu-slot-binds-cached-draw.patch` (E3, `lib/gpu/{shader,render_pass}.{h,cc}`):
  - `Shader_ResolveUniformStruct/Texture` give a uniform name a small index (re-resolved by name on a shader reload).
  - `RenderPass_BindUniformIndexed/BindTextureIndexed` bind by that index without a Dart string.
  - `RenderPass_DrawCached` draws only when the pipeline is already cached on the pass (so it never blocks). Dart can call all of these as leaf calls.
  - The old exports are unchanged.

- `0004-metal-precompiled-shader-libraries.patch` (stage 5):
  - the shader bundle schema gets `BackendShader.compiled`;
  - Flutter GPU registers that `.metallib` with `newLibraryWithData`;
  - it compiles the source only when there is none or it doesn't load.

  flutter_scene P8 fills the field in the build hook. Cold first-launch shader compile stalls drop from ~3 s to ~0.5 s, and the rest is pipeline-state compiles.

- `0005-windows-angle-blob-cache.patch` (stage 5, `shell/platform/windows`): persists ANGLE's compiled programs through `EGL_ANDROID_blob_cache` (see the reference below).
- `0006-gpu-per-attachment-formats-write-mask.patch` (mcsm6, `lib/gpu/{render_pass,context}.{h,cc}`):
  - a pipeline's colour attachments take their own textures' formats (`GetOrCreatePipeline` gave every attachment the render target's, attachment 0's, so a pass mixing RGBA8 and R32F built pipelines that didn't match its targets);
  - `RenderPass_SetColorWriteMask(index, mask)`, part of the pipeline state like the blend;
  - `InternalFlutterGpu_McsmFeatures()`: bits 1 (mixed formats), 2 (write masks), 4 (Dart GC flags in release), 8 (retained draws, 0008). Our Dart (flutter_scene P23) and the runners look it up by symbol.
- `0007-release-dart-gc-flags.patch` (mcsm6, `shell/common/switches.cc`, `shell/platform/common/engine_switches.cc` + its test):
  - release builds accept `--new_gen_semi_max_size`, `--new_gen_semi_initial_size` and `--verbose_gc` as Dart flags (both spellings), and read `FLUTTER_ENGINE_SWITCHES`, keeping only `dart-flags=…` (upstream ignores the environment in release);
  - profile builds also accept `--no-inline-alloc` and `--profile_vm` (complete allocation profiles, native stacks).

- `0008-gpu-retained-draw-lists.patch` (mcsm6, `lib/gpu/{render_pass,context}.{h,cc}`): retained draws. A `DrawList` (Dart wrapper) holds everything a pass's draws sent to the encoder while `RenderPass_BeginRecording` was on (the Impeller pipeline, the uniform and texture bindings with their metadata, vertex and index buffers, counts, stencil, viewport, scissor; each draw is encoded as usual too). `RenderPass_Replay(list, indices, count)` sends chosen draws again, in the given order, through the same encoder calls (Metal: bindings by metadata pointer; other backends: copies), then marks the pass's own bindings to be sent again. Feature bit 8. mcsm's occlusion pass replays each static item's draw (flutter_scene P23/P24, mcsm_look_scene `retained_occlusion.dart`).

- `0009-gpu-cheaper-draws-passes-direct-writes.patch` (mcsm7, `lib/gpu`):
  - **Pipelines across passes:** each `RenderPipeline` keeps the Impeller pipelines built for it, keyed by the pass's pipeline state and its targets' formats and sample count as plain words (a hash and a memcmp; upstream copied, hashed and compared a whole `PipelineDescriptor` and a `std::map` of colour descriptors). A new pass no longer starts with an empty cache. A pass also keeps the pipelines it used lately by (RenderPipeline, cull, winding, primitive, polygon mode) while the rest of the state holds, so a winding flip per draw is one lookup. The state version moves only when a setter changes something. A shader reloaded with new code drops its pipelines.
  - **Bindings** sit in bind-order arrays instead of `unordered_map`s; samplers come from a small per-pass cache; a replayed draw (0008) sends only the bindings and vertex buffers that differ from the draw replayed before it.
  - **`Texture_McsmWriteDirect`** (bit 16): writes a host-visible texture's base level straight into its memory (Metal's `replaceRegion`): no staging buffer, no blit, no command buffer. The caller keeps the GPU off the texture meanwhile.
  - **Several passes on one command buffer** (bit 64): creating a pass ends the encoder of the command buffer's previous pass (Metal allows one open encoder per command buffer, and creates it with the pass), which then refuses draws. Fewer command buffers to create and commit.
  - Bit 32 is unused: a batched encoding (a pass's binds and draws as words, sent in one call) was built and measured no cheaper than the leaf calls, and dropped.
- `0010-impeller-gles-mrt-metal-binding-cache.patch` (mcsm7, `impeller/renderer/backend`):
  - **GLES: several colour attachments in one pass** (bit 128): attachments 1…N on the cached FBO (re-attached when the set changes), `glDrawBuffers`, a `glClearBufferfv` per attachment, discards, and per-buffer blend state and write masks where the driver has them (GLES 3.2, GL 4.0, `OES_draw_buffers_indexed`; one shared state when the attachments agree). Upstream bound only the first attachment. Not for multisampled attachments past the first.
  - **Metal:** `SetPipeline` with the pipeline the encoder already holds only re-arms the draw (no state, winding, cull or fill-mode calls), and `PassBindingsCacheMTL` keeps the vertex and fragment stages' first 32 buffer, texture and sampler slots in flat arrays (two `std::map` lookups per bind before).

- `0011-gpu-metal-viewport-arrays.patch` (mcsm7, `lib/gpu`, `impeller/renderer/backend/metal`): **viewport arrays** (bit 256). `RenderPass_McsmSetViewports` takes up to 16 viewports (x, y, w, h, z near, z far) and a scissor rect for each; the draws that follow set them on the encoder (`setViewports:count:` / `setScissorRects:count:`) and each primitive goes to the viewport its vertex stage names (flutter_scene P34 turns a `flat out uint mcsm_viewport_index` output into Metal's `[[viewport_array_index]]`). A draw without them, a replay or count 0 goes back to one viewport. Metal only: other backends return false and the caller draws per tile (GLES 3.0 has no viewport index in the vertex stage; Vulkan's multiViewport comes with mcsm8). One instanced draw into 4 tiles gives the same bytes as 4 per-tile draws (gpu_smoke).
- `0012-gpu-first-instance-draws.patch` (mcsm7, `lib/gpu`): **draws from a first instance** (bit 512). `RenderPass_McsmDrawInstanced(count, instances, first, indexed)` (leaf; 2 = no cached pipeline yet) offsets every bound instance-rate vertex buffer by `first · stride` for that draw and records the offset views (0008), on every backend, so the shader's instance index counts from 0 everywhere (Metal's `baseInstance` would start `[[instance_id]]` at `first`; GLES 3.0 has no base instance). One instance buffer serves many draws without a bind per draw. flutter_gpu G7 exposes it as `draw(…, firstInstance:)` / `drawIndexed(…, firstInstance:)`.

- `0013-embedder-vulkan-backing-stores.patch` (mcsm8, `shell/platform/embedder`, `shell/gpu`): the embedder API's Vulkan backing stores for Impeller (the embedder's `VkImage` wrapped as the resolve target of a 4× MSAA layer, with its own depth/stencil per backing store, left in `COLOR_ATTACHMENT_OPTIMAL`); with a compositor the Impeller Vulkan surface renders nothing itself (`render_to_surface`), and it gets a pipeline cache directory on the desktop (persisted every 50 frames; per-thread command pools recycled as `SurfaceContextVK` does).
- `0014-linux-vulkan.patch` (mcsm8, `shell/platform/{common,linux}`): `McsmVulkanDevice` (loader, instance, a device with Impeller's needs plus `multiViewport` and the vertex viewport index where present, the queue's functions behind one mutex for every caller through hooked `vkGet*ProcAddr`, backing-store images, readback), `FlCompositorVulkan`, the renderer choice and its log line; then the zero-copy path (`McsmVulkanExportRing`: three exportable RGBA8 images and semaphores, imported into GDK's GL context by fd, no CPU wait per frame), with the read-back path for several layers or without the GL extensions.
- `0015-windows-vulkan.patch` (mcsm8, `shell/platform/{common,windows}`): Impeller on Vulkan in `FlutterWindowsEngine` unless `MCSM_RENDERER=gles` or Impeller is off; `CompositorVulkan` presents through `McsmVulkanSwapchain` (a swapchain per view on its HWND, BGRA8, FIFO only when DWM doesn't compose, one frame in flight, rebuilt when out of date); views create, resize and destroy the swapchain where they did the EGL surface; ANGLE as before otherwise.
- `0016-gpu-vulkan-features-viewport-arrays.patch` (mcsm8, `lib/gpu`, `impeller/renderer/backend/vulkan`): feature bits per backend (bit 1024; `InternalFlutterGpu_McsmBackend`), Vulkan ending a command buffer's previous pass when the next begins (it encodes as it goes, as Metal), and **viewport arrays on Vulkan** (bit 256): 16 viewports and scissors, pipelines with a viewport count (part of the pipeline key); a vertex shader writes `gl_ViewportIndex` under `#ifdef IMPELLER_TARGET_VULKAN` (`GL_ARB_shader_viewport_layer_array`). gpu_smoke: one instanced draw into 4 tiles = 4 per-tile draws, 0 px.
- `0017-impeller-vulkan-memory-render-pass-cache.patch` (mcsm8, `impeller/renderer/backend/vulkan`): correctness. A host-visible buffer that doesn't fit the staging pool's memory type (the 256 MB BAR heap of a discrete GPU) is allocated outside the pool (TownFair ran out of device memory on the RTX). A pass's cached render pass and framebuffer are keyed on its whole attachment set (each texture by a never-reused id, load/store actions, subresource, a loaded attachment's layout) instead of colour 0 alone: a Flutter GPU pass that loaded a target first cleared by another pass cleared it again, and one with a second depth target drew into the first; loaded depth/stencil and colour attachments past the first start in their tracked layout (they started undefined), and an attachment loaded before it was ever written is moved to an attachment layout first. gpu_smoke "pass reuse" checks it. A new Flutter GPU colour texture is cleared to zero and leaves UNDEFINED at once, on a command buffer submitted right away (a bare UNDEFINED → SHADER_READ_ONLY transition left the UHD 620 driver's compression state undefined: garbage blocks in textures uploaded afterwards): Flutter GPU may sample a texture nothing wrote yet, or record its first write in a command buffer submitted after one that samples it, and Impeller's tracked layout then disagreed with the image's (validation errors in four Ep101 scenes).
- `0018-vulkan-cheaper-draws-submits.patch` (mcsm8, `lib/gpu`, `impeller/renderer/backend/vulkan`): what made Vulkan's CPU side slower than GLES's. Bindings (recorded and replayed) go to the pass without a `ShaderMetadata` copy each; a submit or a texture overwrite disposes the thread's pools at most every 16 ms (each dispose made the next command buffer create new pools); signalled fences are reset and reused (`vkCreateFence` cost ~300 µs on NVIDIA); a pass skips unchanged pipeline, descriptor set, vertex and index buffer binds and tracking it already holds; graphics pipelines take uniform buffers as dynamic descriptors (≤ 8) so draws that differ only in their uniform slice share a set, and a pass keeps every set it wrote by its writes. Per draw (gpu_smoke, RTX): bare 0.74 → 0.16 µs; submit 435 → 9 µs.
- `0019-impeller-text-shadow-cache-by-content.patch` (mcsm9, `impeller/entity/contents/text_shadow_cache.{h,cc}`, `impeller/display_list/canvas.cc`): `Canvas::AttemptBlurredTextOptimization` keys a blurred text by the text frame's content (runs, fonts, positioned glyphs, bounds), its stroke and its transform without the whole-pixel translation. Upstream keyed it by the `TextFrame`'s heap address and the transform's scale: a freed frame's address came back for another text, which then drew the first text's shadow, and a shadow rendered at one sub-pixel position stood in for another, so a frame depended on the allocator and on the frames before it. A shadow is now reused only where it renders the same pixels moved by whole pixels.
- `0020-impellerc-uniform-blocks-storage-targets.patch` (mcsm9, `impeller/compiler`, `impeller/shader_bundle/shader_bundle.fbs`):
  - **Uniform limit:** Metal and Vulkan shaders (not runtime stages) limit each uniform block to 64 KB, Direct3D 11's constant buffer size (desktop Vulkan drivers take 64 KB or more); upstream limited all blocks of a shader together to 6,208 bytes, a GLES budget that GLES keeps. S2's light data block is 12,288 bytes.
  - **Storage resources:** bundles record storage buffers and storage images (name, Metal index, set, binding, read-only) and a compute shader's workgroup size (new fields at the end of `BackendShader`: older engines read the bundles, and S1's bundles come out byte-identical).
  - **Targets:** a bundle entry may name its backends (`"targets": ["metal_desktop", "vulkan"]`), so shaders that need Metal or Vulkan leave out the GL backends, which can't compile them. A vertex stage writing `gl_Layer` needs `--metal-version=2.2` or later.
  - **Texel buffers and separate samplers:** `samplerBuffer`/`imageBuffer` are recorded as texel buffers (Metal `texture_buffer` from MSL 2.1, with an image-atomic buffer index where Metal emulates atomics), `texture2D` and `sampler` declared apart as separate textures and samplers; Metal gives separate images and samplers explicit indices after the combined ones (SPIRV-Cross's automatic ones collided), and compute shaders bind as the compute stage.
  - **Per-shader options:** `"metal_preserve_invariance"` and `"metal_safe_math"` (recorded in the bundle, applied when Metal compiles the source: invariant positions, fast math off) and `"spirv_optimize": false` (spirv-opt's folds aren't IEEE-exact: it turned `x * -1 + 0` into `-x`). S1's bundles stay byte-identical.
- `0021-impeller-s2-formats-layered-textures-compute.patch` (mcsm9, `impeller/core`, `impeller/renderer`, `shell/platform/common/mcsm_vulkan_device.cc`): what S2's frame needs, on Metal and Vulkan (GLES refuses it):
  - **Formats:** every uncompressed format Metal and Vulkan share (R11G11B10 and RGB9E5 float, RGBA16 unorm and snorm, RGB10A2, 8/16/32-bit integer and signed-normalized, R16/RG16/RG32 float), D16 and D32 float, BC2, BC4, BC5 signed and BC6H (after the stock values); 2x MSAA.
  - **Textures:** 2D arrays, 3D textures and cube arrays (`TextureDescriptor::array_layer_count`, `depth`), uploaded per layer or depth slice; texture views of a mip range and layer range (`Context::McsmMakeTextureView`: one level rendered while another is sampled, one layer as a 2D target); depth-only render targets; sampled (and multisampled) depth.
  - **Passes:** an attachment slice `kMcsmAllLayers` attaches every layer (Metal `renderTargetArrayLength`, Vulkan layered framebuffers) and the vertex stage picks each primitive's layer; indirect draws and dispatches (`McsmSetIndirect`); storage images in compute passes.
  - **Samplers:** a comparison function, clamp-to-border with the border colours both backends have, mirror-clamp-to-edge, LOD clamps and (Vulkan) a LOD bias; textures and samplers bound apart (`McsmBindSeparateTexture`, `McsmBindSeparateSampler`).
  - **Texel buffers:** a buffer range read or written as typed texels (`McsmBindTexelBuffer`: Metal texture-buffer views of the buffer, cached on it, plus the atomic view's buffer; Vulkan uniform and storage texel buffer views, cached on the buffer and tracked per command buffer).
  - **Metal compile options:** `ShaderLibrary::McsmRegisterFunction` compiles source with preserved invariance and safe math when the bundle asks.
  - **Vertex input:** half, normalized and packed attribute formats (`ShaderStageIOSlot::mcsm_format`) and per-instance step rates.
  - **Copies:** between mip levels and slices of textures, and to buffers (`BlitPass::McsmCopyTextureToTexture`, `McsmCopyTextureToBuffer`), restoring each texture's layout; Vulkan mip generation covers every layer.
  - **Vulkan:** compute passes move sampled and storage images to the layouts they read them in (upstream assumed shader-read) and storage images back to shader-read; compute writes are ordered before every later stage (upstream: vertex input only); depth textures that shaders sample end their pass shader-read and are read through a depth-only view; pass dependencies order depth writes; the embedder's device enables the features these use where the GPU has them (BC textures, cube arrays, independent blending, indirect first instance and multi-draw, vertex and fragment stores, extended storage-image formats, gathers with offsets, depth clamp, sample shading, clip and cull distances, draw parameters, mirror-clamp, the vertex attribute divisor); descriptor pools hold storage images, texel buffers and separate images and samplers; buffers may be texel buffers and indirect arguments; a new block-compressed texture isn't cleared (it can't be).
- `0022-gpu-layered-textures-storage-compute.patch` (mcsm9, `lib/gpu`): Flutter GPU's side. `Texture_McsmInitializeLayered` and `Texture_McsmInitializeView`; `RenderPass_McsmBindStorageBuffer` (sent at every draw, not recorded into draw lists), `RenderPass_McsmDrawIndirect`, `RenderPass_McsmBindTextureSampler` (a whole sampler state); `ComputePipeline_McsmInitialize` and `ComputePass_Mcsm*` (uniform and storage buffers, sampled textures, storage images, dispatch, indirect dispatch, barrier); `CommandBuffer_McsmCopyTextureToTexture`, `McsmCopyTextureToBuffer`, `McsmGenerateMipmap`; `RenderPass_McsmBindTexelBuffer`, `McsmBindSeparateTexture`, `McsmBindSeparateSampler` and their compute-pass twins (`Shader_McsmResolveBinding` resolves them); shaders registered with their bundle's Metal options; the added vertex formats and step rates in render pipelines; a slice of -1 attaches every layer; a D16 or D32 float texture is attached as depth only (Metal refuses a stencil attachment without stencil bits); feature bit 2048 on Metal and Vulkan. flutter_gpu G9 is the Dart side, gpu_smoke's mcsm9 checks use all of it.

The Dart side of E3 is `third_party/flutter_gpu` (G1–G3). It detects these exports and falls back to the stock calls on Flutter's prebuilt engine. mcsm6's capabilities are found by flutter_scene P23 (it builds against Flutter's own flutter_gpu).

## mcsm6 results (2026-10-22, M2 Pro, interleaved A/B under measure.sh; the machine was loaded, so pairs, not absolutes)

- **Occlusion buffer in the exe's layout** (0006): render targets in WildernessTile 1,327 → 963 MB. On Metal both engines run the same shaders (`tt_shadow_*8`; Flutter's engine with every target RGBA32F), so their frames are byte-identical (six capture sets). Against mcsm5's frames: 8 pixels over 19 frames, at most 2 levels, at far pixels where the filter's taps fall between texels. The taps are now done in the shader as the hardware's bilinear on the exe's RGBA8 bytes with an 8-bit weight; Metal's own sampler filtered the RGBA32F values with other arithmetic. GLES is unchanged.
- **Dart new generation** (0007, runners): default 64 MB. Scavenge pauses per second at 16 → 32 → 64 MB: MagnusCourtyard 36 → 26 → 19 ms, EllieWitherstorm 38 → 22 → 14, TownFairDestroyed 43 → 31 → 22, WildernessTile 49 → 32 → 21, TownFair 41 → 29 → 17. Scavenges ~38 → ~10 a second, each ~2 ms instead of ~1.1. Frame times are unchanged within noise. Checked on Linux and Windows through the runners (`MCSM_DART_FLAGS=--verbose_gc`).
- **Retained draws** (0008) for the occlusion pass: byte-identical (six capture sets). The pass's CPU time per frame, immediate → retained: WildernessTile 1.59 → 1.36 ms, EllieWitherstorm 1.88 → 1.60, TownFair 2.16 → 1.87, MagnusCourtyard 1.28 → 0.99; ~70 % of its draws are replays. What is left per replayed draw is Metal's own encoding (pipeline state, bindings, the draw: ~0.9 µs) and the per-item culling and checks (~0.8 µs). Going further needs Metal indirect command buffers, or fewer draws.
- **Glow mask over the depth prepass** (uses no new engine API; `--glow-mask=prepass`, off by default until judged against the exe): TtGlow 1.0 → 0.25 ms, scene render −0.4 to −0.8 ms a frame (four scenes). It changes the frame where a glow set and a non-glow set of one mesh meet at one depth: as the exe's Glow pass does (LESSEQUAL over the G-buffer depth), the glow shows (glowstone lamps get a halo). Before/after frames and exe shots: `data/reference/oracle/mcsm6-glow`.
- **Archives checked the way users get them:** macOS arm64 and x86_64, Linux x64 and Windows x64 — `fetch.sh`/`fetch.ps1` from the file, then the player built on it: the treehouse D1 capture (frames, events, audio) identical to the stock engine's on that OS. The Windows archives now carry `flutter_windows.dll.exp` and an empty `.pdb` (the Flutter tool's `unpack_windows` copies both; without them a build from the archive failed, as it would have with mcsm5's).

## mcsm7 results (2026-10-26, M2 Pro unless noted)

- **Per draw** (gpu_smoke scene-like draw: 2 vertex buffers, 2 uniform blocks, 3 textures, cull + winding per draw, best of 7 × 2,000): stock 2.0 µs, mcsm6 0.74, mcsm7 ~0.6. Bare draw 0.13 → 0.07 µs.
- **gpu_smoke mcsm7 checks** (all built from the unpacked archives): macOS arm64 and x64 — instancing, first-instance draws (0 px vs offset bindings, plain and indexed), MRT RGBA8 + R32F, a G-buffer pass (RGBA8 + R32F + depth with the depth test), direct writes, viewport arrays (0 of 4,096 px vs per-tile draws), features 991. Linux x64 (GLES, RTX 4060 Ti under a headless GNOME Shell) — the same except viewport arrays and direct writes ("not on this backend": casters draw per tile, textures upload the usual way). Windows: see the targets below. On the stock engine first-instance draws take the Dart fallback (0 px); MRT with mixed formats is not claimed there.
- **Captures:** the branch's 11 capture sets (frames, events, audio) are byte-identical to main's on mcsm6, on the stock, mcsm6 and mcsm7 engines and on the player built from the macos-arm64 archive. Linux x64: stock vs mcsm7 treehouse D1, TownFair and TownFairHall captures identical.
- **Scenes** (scene_bench vs main on mcsm6, interleaved): the UI thread's scene render −0.4..−0.5 ms a frame (TownFair 3.97 → 3.52, TownFairHall 3.14 → 2.75, EllieWitherstorm 4.18 → 3.68 ms p50), shadows −0.1..−0.3 ms; frames over 16.7 ms TownFair 7.8 → 5.4 %, EllieWitherstorm 13.7 → 7.6 %. docs/memory/status-perf.md "mcsm7" has the table.

## Reference: targets, backends, test results (2026-10-17)

The same patches on each platform. E1 and E3 are backend-neutral. E2's retained bindings and 0004 are Metal-only: other backends take the stock paths.

**Which backend Flutter GPU runs on:**

| Platform | Backend | Embedder |
|---|---|---|
| macOS | Metal | |
| Windows | GLES through ANGLE on Direct3D 11 (since mcsm8: Vulkan where it works, ANGLE as the fallback) | `windows/egl` (mcsm8: `windows/compositor_vulkan`) |
| Linux | GLES/GL (since mcsm8: Vulkan where it works) | the GTK embedder; upstream it supports only OpenGL and software (`fl_engine.cc`; mcsm8 adds `fl_compositor_vulkan`) |

So before mcsm8 no desktop embedder ran Impeller's Vulkan backend (mcsm8 gives Vulkan its pipeline cache directory, above). The cross-launch shader cache per platform:
- **macOS:** the precompiled `.metallib` bundles (0004 + flutter_scene P8).
- **Windows:** patch 0005 persists ANGLE's compiled programs (D3D bytecode) through `EGL_ANDROID_blob_cache`, in `%LOCALAPPDATA%\<exe>\flutter_angle_cache` (`FLUTTER_ANGLE_BLOB_CACHE=0` turns it off).
- **Linux:** Mesa and NVIDIA keep their own on-disk shader caches.

**Out dirs** (`<engine/src>/out/<name>`; give `--local-engine=<name> --local-engine-host=<name>`):

| Target | Where built | gn | Out dir | Size | First build |
|---|---|---|---|---|---|
| macOS arm64 | this Mac, `build.sh build` | `--mac-cpu=arm64` | `host_release_arm64` | 4.6 GB | ~1 h CPU |
| macOS x86_64 | this Mac, `MCSM_ENGINE_CPU=x64 build.sh build` | `--mac-cpu=x64` | `host_release` | 2.6 GB without `obj/` | 13 min at 6 jobs |
| Linux x64 | workstation, `linux.sh build` | (host) | `host_release` | 0.7 GB | 10 min at 10 jobs |
| Linux arm64 | workstation (cross, Debian sysroot) | `--target-os=linux --linux-cpu=arm64` | `linux_release_arm64` | 0.9 GB | 12.5 min |
| Windows x64 | Windows VM, `windows.ps1` | (host) | `host_release` | 2.5 GB | 23 min at 10 jobs |
| Windows arm64 | Windows VM (cross) | `--windows-cpu arm64` | `host_release_arm64` | 3.6 GB | 35 min |

The workstation keeps its checkout in `$MCSM_WS_ROOT/engine` (11 GB of sources; 19 GB with the outs, the test build, a Flutter SDK and the smoke Docker context). The VM keeps its own in `C:\mcsm\engine` (15.8 GB with both outs). The VM's toolchain comes from `windows-toolchain.ps1`. `docs/memory/reference-linux-workstation.md` has the access details.

**macOS universal:** the Flutter tool builds a local-engine macOS app for one architecture only. It sets `ARCHS` from the engine's name: `_arm64` → arm64, otherwise x86_64 (`xcode_build_settings.dart`). For a universal app:
1. Build once with `MCSM_LOCAL_ENGINE_NAME=host_release_arm64` and once with `host_release`, copying each `.app` aside.
2. Run `apps/mcsm_player/tool/universal_app.sh <arm64.app> <x86_64.app> <out.app>`. It lipos every Mach-O file, merges `NativeAssetsManifest.json`, keeps the arm64 engine's Info.plist (it differs only in the engine revision string), and signs the result ad hoc.
- **Checked:** both slices of the merged player run the patched engine (`arch -arm64` / `arch -x86_64`, `--gpu-bench` 0.124 / 0.199 µs bare draw). The x86_64 build's treehouse D1 frames are byte-identical to the arm64 build's.
- **Not engine-related:** `audio.wav` differs between the two architectures. The Rust mixer's float results differ between arm64 and x86_64.

**Tests:**
- **Linux x64, debug test build** (`out/host_debug_unopt_tests`, SwiftShader):
  - `impeller_unittests --gtest_filter=*/Vulkan:-*Playground*` under Xvfb with the validation layers: 711 passed, 21 skipped, 0 failed.
  - `gpu_unittests`: the RenderPass suite (1) and the ShaderLibrary suite (6) pass. The CommandBuffer suite aborts in debug (`ref_counted_internal.h: !adoption_required_`), because its test puts a ref-counted `CommandBuffer` on the stack. That is an upstream test bug in files we don't patch.
- **`tools/gpu_smoke`** (a minimal Flutter GPU app: render through flutter_scene's base shaders, read back, time draws):
  - **macOS arm64:** pixel ok; draw 0.117 µs, draw + texture bind 0.194 µs.
  - **Linux x64** (Docker `mcsm-linux-smoke`, Xvfb + Mesa llvmpipe; stock → patched): it builds and runs on both engines. Draw 0.878 → 0.197–0.221 µs; draw + bind 0.98–1.06 → 0.20–0.22 µs.
    - The pixel read back is `[0, 0, 0, 0]` on the **stock engine too**, so it isn't the patches: `Texture.asImage` readback on GLES/llvmpipe gives zeros even after the command buffer completes.
    - A rendering check on Linux needs a different readback, or a real GPU. Since 2026-10-17 gpu_smoke draws the texture into a `Picture` and reads that back, as the player's captures do: the pixel is right on llvmpipe.
  - **Windows x64** (the VM: ANGLE on WARP, the arm64 engine building alongside; stock → patched): it builds and runs on both engines. Draw 3.39 → 0.45–0.49 µs; draw + bind 5.38 → 0.48–0.59 µs. The readback is zero on both engines, as on Linux.
    - Patch 0005's cache works: the patched app wrote 73 programs (301 KB) to `%LOCALAPPDATA%\gpu_smoke\flutter_angle_cache`.
    - The smoke's own first draw is 8 ms cold and 5 ms warm, which is too little work to show the cache's effect. The player (2026-10-17, VM, WARP) wrote 89 programs; its treehouse D1 capture took 32 s cold and 29 s warm, so in a capture the cache saves ~3 s.
- **The player on Linux x64 and Windows x64** (2026-10-17): built on the stock and the patched engine; the treehouse D1 capture (frames, events, audio) is byte-identical between the two engines on each OS (docs/superpowers/plans/2026-10-17-players-linux-windows.md).
- **Linux arm64 and Windows arm64:** these were only checked for building. Linux arm64's `libflutter_linux_gtk.so` is an aarch64 ELF with the patch exports, and gen_snapshot is x64-hosted. Neither ran: there is no arm64 machine, and qemu-user wasn't tried.

