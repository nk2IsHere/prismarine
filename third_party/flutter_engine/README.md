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

## Using it

- Set `MCSM_LOCAL_ENGINE=$MCSM_DATA/engine/flutter/engine/src` in `.env`. `tools/toolchain/env.sh` then sets `mcsm_engine_args`.
- `apps/mcsm_player/tool/play.sh` passes those args to its release build: `--local-engine-src-path=… --local-engine=host_release_arm64 --local-engine-host=host_release_arm64`.
- The app becomes arm64-only, because the Flutter tool sets `ARCHS=arm64` for an `_arm64` local engine. The Rust hooks (mcsm_cargo) build for the architectures the tool asks for, so only `aarch64-apple-darwin`. A mirror that built universally before may keep a cached universal dylib, which still runs.
- Unset (the default), everything builds with Flutter's prebuilt engine.
- Profile and debug builds always use the prebuilt engine.
- After a Flutter upgrade: point `build.sh` at the new `engine.version`, re-apply the patches (fix conflicts), and rebuild.
