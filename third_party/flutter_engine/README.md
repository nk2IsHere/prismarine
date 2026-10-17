# The Flutter engine, patched for mcsm

mcsm draws through Flutter GPU, and on the stock Flutter engine every draw costs about 0.9 µs of CPU before our own code runs. The patches here cut that to ~0.12 µs on Macs (TownFair's paint −1.7 ms a frame). They also load our Metal shaders precompiled (a fresh build's first scene no longer stalls ~3 s) and cache ANGLE's compiled programs on Windows.

**The patched engine is optional.** Everything builds and runs on Flutter's stock engine too, only slower, and the frames are byte-identical either way. The patches apply to the engine of the project's Flutter (3.47.7 stable, engine revision `deb287481e3ce9468f3434937ced4240a70539ca`). They live here as reviewable files; the downloaded or built engine is data (`$MCSM_DATA/engine`, gitignored).

**Where it's useful today:** the game player (`apps/mcsm_player`) on macOS, Linux and Windows: each play script (`tool/play.sh`, `tool/linux/play.sh`, `tool/windows/play.ps1`) builds on it when it is there. `tools/gpu_smoke` runs on it too.

Contents:
- [Get the engine: download it](#download-it-a-minute)
- [Or build it yourself](#or-build-it-yourself): [macOS](#macos-arm64-and-x86_64), [Linux](#linux-x64-native-and-arm64-cross-built), [Windows](#windows-x64-native-and-arm64-cross-built)
- [Use it](#use-it)
- [Publish a new build](#publish-a-new-build-maintainers)
- [Patches](#patches)
- [Reference](#reference-targets-backends-test-results-2026-10-17)

## Download it (a minute)

The repo's GitHub release `engine-deb287481e3c-mcsm5` (tag in `RELEASE`) holds the engine for six targets, 14–21 MB each. Each archive contains only what a release `flutter build … --local-engine` reads.

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
- **Verified:** a fresh `fetch.sh` on an arm64 Mac, then `play.sh`, builds and plays on it (`--gpu-bench` bare draw 0.12–0.13 µs, against 0.87–0.89 on the stock engine). The Intel Mac, Linux x64 and Windows x64 archives were each checked by building from the unpacked archive. The arm64 Linux and Windows archives were built but not run (no arm64 machine).

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
- Profile and debug builds (`profile.sh`, `flutter run`) always use the stock engine.
- An app built on the patched engine is for one CPU only: the Flutter tool sets `ARCHS` from the engine's name.
- **Universal app** (to share it): build once per engine and copy each `.app` aside, then run `apps/mcsm_player/tool/universal_app.sh <arm64.app> <x86_64.app> <out.app>`.
- The patched and stock engines can take turns in one build dir; the Flutter tool rebuilds what changed.

**Linux and Windows:** `apps/mcsm_player/tool/linux/play.sh` and `tool/windows/play.ps1` find a fetched or built engine as `play.sh` does on macOS (`MCSM_LOCAL_ENGINE`, `MCSM_LOCAL_ENGINE_NAME`). By hand, pass the flags to `flutter build`:

    flutter build linux   --release --local-engine-src-path=<…>/engine/src --local-engine=host_release --local-engine-host=host_release
    flutter build windows --release --local-engine-src-path=<…>\engine\src --local-engine=host_release --local-engine-host=host_release

- **`<…>/engine/src`** is `$MCSM_DATA/engine/<target>/src` for a fetched engine, or `<MCSM_ENGINE_DIR or EngineDir>/flutter/engine/src` for a built one.
- **Arm64 machines:** use `linux_release_arm64` or `host_release_arm64` for both flags.
- **A self-built out dir** needs the `flutter_patched_sdk_product` link; the build scripts make it.
- **Try it with `tools/gpu_smoke`:** `flutter build <os>` it with those flags and run it. It prints `SMOKE` lines with the per-draw times. On Windows, `tools\gpu_smoke\windows_smoke.ps1 -EngineSrc <…>\engine\src` builds and runs it on the stock engine and then the patched one.

## Publish a new build (maintainers)

1. Bump `RELEASE` (e.g. `engine-<engine revision, 12 chars>-mcsm<patch count>`).
2. Package each target where it was built:
   - macOS and Linux: `package.sh <engine/src> <out dir> <target> <dest> [<host out dir>]`;
   - Windows: `package.ps1 -Src … -Out … -Target … -Dest … [-HostOut …]`.
   
   Each makes `mcsm-engine-<target>.tar.xz` and `.sha256`. `package.sh` records `MCSM_ENGINE_REV` (default `deb287481e3c…`).
3. Check each archive the way users get it: `fetch.sh` with `MCSM_ENGINE_ARCHIVE=<file>`, or `fetch.ps1 -Archive <file>`, into a scratch `MCSM_DATA`, then build the player or gpu_smoke from it.
4. Run `gh release create <tag> -R <owner>/<repo> --title … --notes-file … mcsm-engine-* SHA256SUMS`. An asset must be under 2 GiB; ours are ~20 MB.

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

The Dart side of E3 is `third_party/flutter_gpu` (G1–G3). It detects these exports and falls back to the stock calls on Flutter's prebuilt engine.

## Reference: targets, backends, test results (2026-10-17)

The same patches on each platform. E1 and E3 are backend-neutral. E2's retained bindings and 0004 are Metal-only: other backends take the stock paths.

**Which backend Flutter GPU runs on:**

| Platform | Backend | Embedder |
|---|---|---|
| macOS | Metal | |
| Windows | GLES through ANGLE on Direct3D 11 | `windows/egl` |
| Linux | GLES/GL | the GTK embedder; it supports only OpenGL and software (`fl_engine.cc`) |

So no desktop embedder runs Impeller's Vulkan backend, and a `VkPipelineCache` on disk wouldn't help any of them. The cross-launch shader cache per platform:
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

The workstation keeps its checkout in `/mnt/storage/mcsm/engine` (11 GB of sources; 19 GB with the outs, the test build, a Flutter SDK and the smoke Docker context). The VM keeps its own in `C:\mcsm\engine` (15.8 GB with both outs). The VM's toolchain comes from `windows-toolchain.ps1`. `docs/memory/reference-linux-workstation.md` has the access details.

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

