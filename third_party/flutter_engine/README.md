# The Flutter engine, patched for mcsm (perf E)

Flutter GPU's per-draw CPU cost was the floor of the paint in TownFair (spec `docs/superpowers/specs/2026-10-16-perf-e-engine-design.md`, plan `docs/superpowers/plans/2026-10-16-perf-e-engine.md`). These patches apply to the engine of our Flutter (`data/flutter`, 3.47.7 stable, engine revision `deb287481e3ce9468f3434937ced4240a70539ca`, `bin/internal/engine.version`). They live here as reviewable patches (docs/memory/feedback-own-the-tooling.md); the checkout and its build are data (`$MCSM_DATA/engine`, gitignored).

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

## Building

`third_party/flutter_engine/build.sh all`. It needs `xcodebuild -downloadComponent MetalToolchain` once (Xcode 27 ships without `metal`, and Impeller's own shaders need it).

1. **setup:** depot_tools, a `--shared` clone of `data/flutter` at the revision, `.gclient` without Android/JDK/esbuild/Fuchsia, then `gclient sync --no-history`. This takes ~13 GB and 20–40 min.
2. **patch:** `git am` of `patches/*.patch` on branch `mcsm-engine`.
3. **build:** gn for `host_release_arm64` (release, no LTO, prebuilt Dart SDK, no unit tests), then ninja of only what a release `flutter build macos --local-engine` reads: FlutterMacOS.xcframework, gen_snapshot, the patched SDK, sky_engine, frontend_server, font-subset and const_finder. Then the `flutter_patched_sdk_product` link.
   - `out/` is ~4.6 GB.
   - The first build took ~1 h of CPU (6 jobs).
   - A rebuild after a `lib/gpu` edit is 1–3 min: `ninja -C out/host_release_arm64 flutter/shell/platform/darwin/macos:flutter_framework`, with depot_tools on PATH for `vpython3`.

Don't build `flutter/build/archives:artifacts`: it pulls in flutter_tester and ANGLE, which fails under the macOS 27 SDK (`-Wignored-attributes`). The app doesn't need it; impellerc falls back to the cache's.

**Disk trimmed on this Mac** (all can be re-fetched by `gclient sync`; no target we build uses them):
- `flutter/buildtools/{linux-x64,mac-x64}` (other hosts' clang);
- `flutter/third_party/java/openjdk`;
- `flutter/third_party/swiftshader/{tests,third_party/llvm-16.0}`;
- `swiftshader/third_party/llvm-10.0`'s non-`.gn` files.

## Every desktop target (2026-10-17)

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
    - A rendering check on Linux needs a different readback, or a real GPU.
  - **Windows x64** (the VM: ANGLE on WARP, the arm64 engine building alongside; stock → patched): it builds and runs on both engines. Draw 3.39 → 0.45–0.49 µs; draw + bind 5.38 → 0.48–0.59 µs. The readback is zero on both engines, as on Linux.
    - Patch 0005's cache works: the patched app wrote 73 programs (301 KB) to `%LOCALAPPDATA%\gpu_smoke\flutter_angle_cache`.
    - The smoke's own first draw is 8 ms cold and 5 ms warm, which is too little work to show the cache's effect. The player's ~100 programs would show it, but the player has no Windows runner.
- **Linux arm64 and Windows arm64:** these were only checked for building. Linux arm64's `libflutter_linux_gtk.so` is an aarch64 ELF with the patch exports, and gen_snapshot is x64-hosted. Neither ran: there is no arm64 machine, and qemu-user wasn't tried.

## Using it

- Set `MCSM_LOCAL_ENGINE=$MCSM_DATA/engine/flutter/engine/src` in `.env`. `tools/toolchain/env.sh` then sets `mcsm_engine_args`. `MCSM_LOCAL_ENGINE_NAME` picks the out dir: `host_release_arm64` (the default) or `host_release` (x86_64).
- `apps/mcsm_player/tool/play.sh` passes those args to its release build: `--local-engine-src-path=… --local-engine=host_release_arm64 --local-engine-host=host_release_arm64`.
- The app becomes arm64-only, because the Flutter tool sets `ARCHS=arm64` for an `_arm64` local engine. The Rust hooks (mcsm_cargo) build for the architectures the tool asks for, so only `aarch64-apple-darwin`. A mirror that built universally before may keep a cached universal dylib, which still runs.
- Unset (the default), everything builds with Flutter's prebuilt engine.
- Profile and debug builds always use the prebuilt engine.
- After a Flutter upgrade: point `build.sh` at the new `engine.version`, re-apply the patches (fix conflicts), and rebuild.
