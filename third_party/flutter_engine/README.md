# The patched Flutter engine

The patches here make Flutter GPU cheaper and wider. On the stock engine a draw costs about 0.9 µs of CPU before the
code of the app runs and the patches bring that to about 0.12 µs on a Mac. They load precompiled Metal shaders, cache
the compiled programs of ANGLE on Windows and let a render pass mix target formats. Release builds take the size of the
Dart new generation as a flag. Windows and Linux run Impeller on Vulkan, see [Vulkan on Windows and
Linux](#vulkan-on-windows-and-linux). Flutter GPU gains formats, texture arrays, 3D textures, compute, texel buffers and
texture views. The passes of a frame are released at submit and the Dart VM collects at an idle point that the app
picks.

The patched engine is optional. Every app builds and runs on the stock engine of Flutter too, only slower and the
frames are byte-identical on both. The patches apply to the engine of Flutter 3.47.7 stable, engine revision
`deb287481e3ce9468f3434937ced4240a70539ca`. The patches are files in this directory. A downloaded or built engine is
data in the engine directory, which is not in git.

The Dart side of the patches is [third_party/flutter_gpu](../flutter_gpu/PATCHES.md). It finds the exports of the
patched engine by symbol and falls back to the stock calls on the prebuilt engine. `tools/gpu_smoke` checks an engine on
a platform.

## Settings

The scripts read these settings from the environment. Each one is also read in its `MCSM_` form, such as
`MCSM_ENGINE_REPO`.

| Setting | Meaning |
|---|---|
| `PRISMARINE_ENGINE_DIR` | The engine directory, with the fetched targets in `<dir>/<target>` and a built engine in `<dir>/flutter`. The default of the fetch scripts is `~/.prismarine/engine`, the engine directory of the toolchain. |
| `PRISMARINE_FLUTTER` | The Flutter SDK. The default is the `flutter` on `PATH`. |
| `PRISMARINE_ENGINE_REPO` | The GitHub repository of the releases, as owner/name. The default is its value in a `private/config/*.env` above this directory. Releases from prismarine1 on are in the repository of prismarine, the older ones in the one of `MCSM_ENGINE_REPO`. |
| `PRISMARINE_ENGINE_ARCHIVE` | A downloaded archive with its `.sha256` beside it, which `fetch.sh` unpacks in place of the download. |
| `PRISMARINE_ENGINE_CPU`, `_MODE`, `_JOBS`, `_TRIM` | The CPU, runtime mode, ninja jobs and object-file clean-up of `build.sh`. |
| `PRISMARINE_ENGINE_REV` | The engine revision that `linux.sh` checks out and `package.sh` records. |

## Fetching a release

The GitHub release that `RELEASE` gives, now `engine-deb287481e3c-prismarine1`, holds the engine for six targets of 14 to
21 MB each. Each archive holds only what a release `flutter build … --local-engine` reads.

| Target | Archive | Out dir for `--local-engine` |
|---|---|---|
| macOS arm64 | `prismarine-engine-macos-arm64.tar.xz` | `host_release_arm64` |
| macOS Intel | `prismarine-engine-macos-x64.tar.xz` | `host_release` |
| Linux x64 | `prismarine-engine-linux-x64.tar.xz` | `host_release` |
| Linux arm64 | `prismarine-engine-linux-arm64.tar.xz` | `linux_release_arm64` |
| Windows x64 | `prismarine-engine-windows-x64.tar.xz` | `host_release` |
| Windows arm64 | `prismarine-engine-windows-arm64.tar.xz` | `host_release_arm64` |

You need the GitHub CLI, `gh`, logged in to an account that can read the private repository of the releases.

    third_party/flutter_engine/fetch.sh            # the target of this machine, on macOS or Linux
    third_party/flutter_engine/fetch.sh macos-x64  # another target
    powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\fetch.ps1   # Windows

The scripts download the archive and its `.sha256` and check it. They unpack it to `<engine dir>/<target>/` and link
the `dart-sdk` of the engine to the one of the Flutter SDK, which has the same Dart. Then they print the flags for
`flutter build`. Offline, download the archive and its `.sha256` from the release page and set
`PRISMARINE_ENGINE_ARCHIVE=<file>`, or pass `fetch.ps1 -Archive <file>`.

## Building the engine

Each build checks out Flutter at the engine revision and applies `patches/*.patch`. It fetches the dependencies of the
engine with `gclient` of Chromium's depot_tools, which the scripts install and builds only the release targets that the
Flutter tool reads. Plan on several GB of disk and about an hour per machine. The Flutter SDK that builds the app must
be 3.47.7.

A machine that holds the tree of the previous release builds the next one incrementally. Apply only the new patches,
with `git am <patch>` in `<engine dir>/flutter` and `git apply <patch>` for a new Dart patch in
`engine/src/flutter/third_party/dart`, then run the build step alone. For prismarine1 on the tree of mcsm11 these are
0029, 0030, `dart/0003` and `dart/0004`. The builds then took 3 minutes for each macOS target at 6 jobs, 5 minutes for
each Linux target at 10 jobs and 16 minutes for Windows x64 and 22 for arm64 at 12 jobs.

### macOS, arm64 and x86_64

You need Xcode 27 with its command-line tools and the Metal Toolchain, `xcodebuild -downloadComponent
MetalToolchain`, about 0.8 GB. Xcode 27 ships without `metal` and the shaders of the engine need it. The sources take
13 GB in `<engine dir>/flutter`, a shared clone of the Flutter SDK and each out dir takes 2.6 to 4.6 GB.

    third_party/flutter_engine/build.sh all                            # arm64, out/host_release_arm64
    PRISMARINE_ENGINE_CPU=x64 third_party/flutter_engine/build.sh build  # Intel, out/host_release

- `all` runs `setup` with depot_tools, the clone and `gclient sync`, which takes 20 to 40 minutes of downloads, then
  `patch` and `build`.
- The first arm64 build took about an hour on an M2 Pro with 6 jobs. The x64 build took 13 minutes more with the
  sources already built.
- After a patch edit, `build.sh patch` and then `build.sh build` take minutes.
- `PRISMARINE_ENGINE_TRIM=1` deletes the object files of the out dir afterwards, about 2 GB. The next build is then a
  full one.
- `PRISMARINE_ENGINE_MODE=profile` builds `out/host_profile_arm64` for `flutter build macos --profile`. Profile builds
  take `--no-inline-alloc` and `--profile_vm` as Dart flags.
- After an Xcode update the out dir rebuilds in full. Download the Metal Toolchain again first. `gclient sync` made a
  link `MacOSX<version>.sdk` into Xcode in `engine/src/flutter/prebuilts/SDKs`. When the SDK version of Xcode changes,
  point a link with the new version at it and delete the old one, or the compiler finds no sysroot.

### Linux, x64 native and arm64 cross-built

You need an x86_64 Linux machine, with Ubuntu 24.04 and 26.04 tested and `git`, `python3`, `curl`, `xz-utils` and
`pkg-config`. `gclient` brings the compiler and the Debian sysroots for both CPUs. The sources take about 11 GB, each
release out dir about 1 GB and the optional test build 5.4 GB. The builds take about 10 minutes for x64 and 13 for
arm64 on 16 cores after the download.

    export PRISMARINE_ENGINE_DIR=$HOME/flutter-engine
    third_party/flutter_engine/linux.sh setup   # depot_tools, clone, patches, gclient sync
    third_party/flutter_engine/linux.sh build   # out/host_release for x64, out/linux_release_arm64 for arm64
    third_party/flutter_engine/linux.sh test    # optional, the gpu_unittests that the patches touch

The impeller tests on SwiftShader need a display. In Docker with `tools/gpu_smoke/Dockerfile.linux` and
`O=$PRISMARINE_ENGINE_DIR/flutter/engine/src/out/host_debug_unopt_tests`, run
`VK_ICD_FILENAMES=$O/vk_swiftshader_icd.json VK_LAYER_PATH=$O/vulkan-data VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation LD_LIBRARY_PATH=$O xvfb-run -a -s "-screen 0 1280x800x24 -extension MIT-SHM" $O/impeller_unittests "--gtest_filter=*/Vulkan:-*Playground*"`.
They give 711 passes and 21 skips.

A Flutter app for Linux also needs the usual Linux desktop packages of Flutter, `clang cmake ninja-build pkg-config
libgtk-3-dev liblzma-dev`, which `tools/gpu_smoke/Dockerfile.linux` installs.

### Windows, x64 native and arm64 cross-built

You need Windows 10 or 11 on x64, an elevated PowerShell and about 30 GB free. The sources take about 10 GB and the out
dirs 2.5 GB for x64 and 3.6 GB for arm64. A long build must run where closing a terminal or an SSH session does not stop
it, such as a scheduled task. `windows-toolchain.ps1` installs the tools.

- Git and Python 3.12 through winget.
- Visual Studio 2022 Build Tools with `Microsoft.VisualStudio.Workload.VCTools`,
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`, `…VC.Tools.ARM64`, `…VC.ATL`, `…VC.ATL.ARM64` and
  `Microsoft.VisualStudio.Component.Windows11SDK.22621`.
- The Debugging Tools for Windows of the Windows SDK 10.0.22621, winget `Microsoft.WindowsSDK.10.0.22621` with the
  feature `OptionId.WindowsDesktopDebuggers`.
- Long paths, `LongPathsEnabled=1` and `git config --system core.longpaths true`.

```
powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\windows-toolchain.ps1
powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\windows.ps1 -EngineDir C:\flutter-engine
```

`windows.ps1` builds `out\host_release` for x64 and `out\host_release_arm64` for arm64, cross-built. `-Cpu
x64|arm64|both` picks the CPUs and the logs go to `<EngineDir>\logs`. A build takes about 25 minutes for x64 and 35 for
arm64 on 10 to 12 cores after a download of about 30 minutes. The arm64 engine is for arm64 Windows machines, since its
`gen_snapshot.exe` is an arm64 program. The Flutter tool builds a Windows app only for the CPU of the machine.

## Using the engine

Pass the engine to `flutter build` of a release build.

    flutter build macos   --release --local-engine-src-path=<…>/engine/src --local-engine=host_release_arm64 --local-engine-host=host_release_arm64
    flutter build linux   --release --local-engine-src-path=<…>/engine/src --local-engine=host_release --local-engine-host=host_release
    flutter build windows --release --local-engine-src-path=<…>\engine\src --local-engine=host_release --local-engine-host=host_release

- `<…>/engine/src` is `<engine dir>/<target>/src` for a fetched engine and `<engine dir>/flutter/engine/src` for a built
  one.
- Arm64 Linux and Windows machines take `linux_release_arm64` and `host_release_arm64` for both flags.
- A self-built out dir needs the `flutter_patched_sdk_product` link, which the build scripts make.
- Debug builds always run on the stock engine. Profile builds run on a self-built profile out dir.
- An app built on the patched engine is for one CPU only. The Flutter tool sets `ARCHS` from the name of the engine, so
  `_arm64` gives arm64 and any other name x86_64. A universal macOS app needs one build per engine and a merge that
  runs `lipo` on every Mach-O file, merges `NativeAssetsManifest.json` and signs the result.
  [`templates/scripts/universal_app.sh`](../../templates/scripts/universal_app.sh) does the merge.
- The patched and stock engines can take turns in one build directory. The Flutter tool rebuilds what changed.
- The runner of an app can set `--new_gen_semi_max_size` before the engine starts, through the Dart flags of patch
  0007. A `FLUTTER_ENGINE_SWITCHES` with `dart-flags=…` reaches release builds too.

## Vulkan on Windows and Linux

The Windows and Linux embedders of Flutter draw with ANGLE and GLES or with GL only. Patches 0013 to 0018 give both an
Impeller Vulkan path, used by default where the machine has a working Vulkan device.

- Windows uses its own instance and device through `vulkan-1.dll` and a swapchain per view on its window. ANGLE is the
  fallback when no device works. `PRISMARINE_RENDERER=gles` forces ANGLE.
- Linux with GTK uses its own instance and device through `libvulkan.so.1`. Each frame reaches the GL context of GTK
  without a copy through the CPU, through `VK_KHR_external_memory_fd` and `GL_EXT_memory_object_fd` with semaphores, or
  else through a read-back. `PRISMARINE_RENDERER=gles` or `FLUTTER_LINUX_RENDERER=opengl` forces GL and `software` gives the
  software renderer of Flutter.
- The engine logs its choice once, as `renderer: Vulkan <device> (api …, driver …, multiViewport, vertex viewport
  index)` or `renderer: ANGLE/GLES (…)`.
- Impeller keeps its Vulkan pipeline cache in `%LOCALAPPDATA%\<exe>\flutter_vk_cache` or
  `~/.cache/<exe>/flutter_vk_cache`. `FLUTTER_VK_CACHE_DIR=<dir>` moves it and `0` turns it off.
- The feature bits of `InternalFlutterGpu_PrismarineFeatures` are those of the running backend, with bit 1024 set. Vulkan has
  1, 2, 4, 8, 64 and 512 and 256 for viewport arrays where the device has `multiViewport` and a viewport index in the
  vertex stage. GLES has 1, 2, 4, 8, 64, 128 and 512 and Metal 1, 2, 4, 8, 16, 64, 256 and 512.
- On ANGLE, with WARP and the UHD 620, a Flutter GPU texture read back from the UI thread right after its command buffer
  completes can come back empty. The stock engine does the same and the screen is not affected. gpu_smoke reads again
  once before it counts a read as wrong.

## Publishing a release

1. Set `RELEASE` to the new tag, of the form `engine-<engine revision, 12 characters>-<release name>`.
2. Package each target on the machine that built it, with `package.sh <engine/src> <out dir> <target> <dest> [<host out
   dir>]` on macOS and Linux and `package.ps1 -Src … -Out … -Target … -Dest … [-HostOut …]` on Windows. Each makes the
   archive and its `.sha256` and records `PRISMARINE_ENGINE_REV`.
3. Check each archive the way users get it. Run `fetch.sh` with `PRISMARINE_ENGINE_ARCHIVE=<file>`, or `fetch.ps1
   -Archive <file>`, into a scratch engine directory, then build an app or gpu_smoke on it.
4. Run `gh release create <tag> -R "$PRISMARINE_ENGINE_REPO" --title … --notes-file … prismarine-engine-* SHA256SUMS`. An
   asset must be under 2 GiB and these are about 20 MB.

## Patches

The patches apply with `git am` to Flutter at the engine revision. The Dart patches under `patches/dart/` apply
uncommitted to the Dart SDK at its DEPS revision. The engine stamps its Dart SDK hash from the HEAD of that checkout,
which must stay the revision that the kernel files of the Flutter tool carry. The release name in parentheses is the
first release with the patch.

- `0001-mac-link-with-xcode-ld.patch` makes `build/config/mac/BUILD.gn` link with the `ld` of Xcode. The lld of the
  engine cannot parse the `.tbd` files of the macOS 27 SDK, which list `arm64e.x1-macos` targets. The binaries are the
  same code.
- `0002-gpu-pipeline-cache-retained-bindings.patch` changes `lib/gpu/render_pass.{h,cc}`.
  - A pass caches the Impeller pipeline per RenderPipeline and pipeline state. A version counter, bumped by the nine
    exports that set state, makes the common case one compare. Each draw copied, hashed and looked up a full pipeline
    descriptor before.
  - On Metal, bindings go by metadata pointer and only the bindings and vertex buffers that the encoder does not hold
    from the same entry are sent. A check of the last writer per index keeps the old semantics when two entries share
    an index. GLES and Vulkan keep the old path.
- `0003-gpu-slot-binds-cached-draw.patch` changes `lib/gpu/{shader,render_pass}.{h,cc}`.
  `Shader_ResolveUniformStruct` and `Shader_ResolveUniformTexture` give a uniform name a small index, resolved again on
  a shader reload. `RenderPass_BindUniformIndexed` and `RenderPass_BindTextureIndexed` bind by that index without a
  Dart string. `RenderPass_DrawCached` draws only when the pass already has the pipeline and never blocks. Dart can
  call all of these as leaf calls. The old exports are unchanged.
- `0004-metal-precompiled-shader-libraries.patch` adds `BackendShader.compiled` to the shader bundle schema. Flutter GPU
  registers that `.metallib` with `newLibraryWithData` and compiles the source only when there is none or it does not
  load. A build hook that fills the field cuts the shader compile stalls of a first launch from about 3 s to about
  0.5 s.
- `0005-windows-angle-blob-cache.patch` in `shell/platform/windows` keeps the compiled programs of ANGLE through
  `EGL_ANDROID_blob_cache`, in `%LOCALAPPDATA%\<exe>\flutter_angle_cache`. `FLUTTER_ANGLE_BLOB_CACHE=0` turns it off.
- `0006-gpu-per-attachment-formats-write-mask.patch` (mcsm6) changes `lib/gpu/{render_pass,context}.{h,cc}`. The colour
  attachments of a pipeline take the formats of their own textures. Upstream gave every attachment the format of
  attachment 0, so a pass that mixed RGBA8 and R32F built pipelines that did not match its targets.
  `RenderPass_SetColorWriteMask(index, mask)` is part of the pipeline state like the blend.
  `InternalFlutterGpu_McsmFeatures()` returns the feature bits, here 1 for mixed formats, 2 for write masks, 4 for Dart
  GC flags in release builds and 8 for retained draws.
- `0007-release-dart-gc-flags.patch` (mcsm6) changes `shell/common/switches.cc` and
  `shell/platform/common/engine_switches.cc`. Release builds accept `--new_gen_semi_max_size`,
  `--new_gen_semi_initial_size` and `--verbose_gc` as Dart flags in both spellings. They read `FLUTTER_ENGINE_SWITCHES`
  and keep only `dart-flags=…`. Profile builds also accept `--no-inline-alloc` and `--profile_vm`.
- `0008-gpu-retained-draw-lists.patch` (mcsm6) adds retained draws to `lib/gpu/{render_pass,context}.{h,cc}`. A
  `DrawList` holds everything that the draws of a pass sent to the encoder while `RenderPass_BeginRecording` was on: the
  Impeller pipeline, the uniform and texture bindings with their metadata, vertex and index buffers, counts, stencil,
  viewport and scissor. Each draw is encoded as usual too. `RenderPass_Replay(list, indices, count)` sends chosen draws
  again in the given order through the same encoder calls, then marks the bindings of the pass to be sent again.
  Feature bit 8.
- `0009-gpu-cheaper-draws-passes-direct-writes.patch` (mcsm7) changes `lib/gpu`.
  - Each `RenderPipeline` keeps the Impeller pipelines built for it, keyed by the pipeline state of the pass and the
    formats and sample count of its targets as plain words. A new pass starts with that cache. A pass also keeps the
    pipelines it used lately by RenderPipeline, cull, winding, primitive and polygon mode while the rest of the state
    holds. The state version moves only when a setter changes something. A shader reloaded with new code drops its
    pipelines.
  - Bindings are in arrays in bind order and samplers come from a small cache per pass. A replayed draw sends only the
    bindings and vertex buffers that differ from the draw replayed before it.
  - `Texture_McsmWriteDirect`, bit 16, writes the base level of a host-visible texture straight into its memory with
    the `replaceRegion` of Metal. The caller keeps the GPU off the texture meanwhile.
  - Several passes share one command buffer, bit 64. Creating a pass ends the encoder of the previous pass of the
    command buffer, which then refuses draws.
  - Bit 32 is unused.
- `0010-impeller-gles-mrt-metal-binding-cache.patch` (mcsm7) changes `impeller/renderer/backend`.
  - GLES renders to several colour attachments in one pass, bit 128, with `glDrawBuffers`, a `glClearBufferfv` per
    attachment, discards and per-buffer blend state and write masks where the driver has them. Multisampled attachments
    past the first are not supported.
  - On Metal, `SetPipeline` with the pipeline that the encoder holds only arms the draw again. `PassBindingsCacheMTL`
    keeps the first 32 buffer, texture and sampler slots of each stage in flat arrays.
- `0011-gpu-metal-viewport-arrays.patch` (mcsm7) adds viewport arrays on Metal, bit 256.
  `RenderPass_McsmSetViewports` takes up to 16 viewports and a scissor rect for each. Each primitive goes to the viewport
  that its vertex stage gives in a `[[viewport_array_index]]` output. A draw without them, a replay or a count of 0 goes
  back to one viewport. Other backends return false before patch 0016. One instanced draw into 4 tiles gives the same
  bytes as 4 draws per tile.
- `0012-gpu-first-instance-draws.patch` (mcsm7) adds draws from a first instance, bit 512.
  `RenderPass_McsmDrawInstanced(count, instances, first, indexed)` is a leaf call that returns 2 when the pass has no
  pipeline yet. It offsets every bound instance-rate vertex buffer by `first · stride` for that draw on every backend,
  so the instance index of the shader counts from 0 everywhere.
- `0013-embedder-vulkan-backing-stores.patch` (mcsm8) adds Vulkan backing stores for Impeller to the embedder API. The
  `VkImage` of the embedder is the resolve target of a 4x MSAA layer with its own depth and stencil. With a compositor
  the Impeller Vulkan surface renders nothing itself. It gets a pipeline cache directory on the desktop.
- `0014-linux-vulkan.patch` (mcsm8) adds `McsmVulkanDevice` and `FlCompositorVulkan` to the Linux embedder with the
  renderer choice and its log line. The device has the features of Impeller, `multiViewport` and the vertex viewport
  index where present and one mutex for the queue. Frames reach GDK through three exportable RGBA8 images and
  semaphores imported by fd, or through a read-back for several layers or without the GL extensions.
- `0015-windows-vulkan.patch` (mcsm8) runs Impeller on Vulkan in `FlutterWindowsEngine` unless `MCSM_RENDERER=gles`
  is set or Impeller is off. `CompositorVulkan` presents through `McsmVulkanSwapchain`, a BGRA8 swapchain per view on
  its HWND with one frame in flight.
- `0016-gpu-vulkan-features-viewport-arrays.patch` (mcsm8) reports feature bits per backend, bit 1024 and
  `InternalFlutterGpu_McsmBackend`. On Vulkan creating a pass ends the previous pass of the command buffer and viewport
  arrays work with 16 viewports and scissors. A vertex shader writes `gl_ViewportIndex` under `#ifdef
  IMPELLER_TARGET_VULKAN` with `GL_ARB_shader_viewport_layer_array`.
- `0017-impeller-vulkan-memory-render-pass-cache.patch` (mcsm8) fixes Vulkan correctness.
  - A host-visible buffer that does not fit the memory type of the staging pool, such as the 256 MB BAR heap of a
    discrete GPU, is allocated outside the pool.
  - The cached render pass and framebuffer of a pass are keyed on the whole attachment set, with each texture by an id
    that is not reused, its load and store actions, its subresource and the layout of a loaded attachment. Loaded depth,
    stencil and colour attachments past the first start in their tracked layout. An attachment loaded before any write
    is moved to an attachment layout first.
  - A new colour texture is cleared to zero and leaves UNDEFINED at once, on a command buffer submitted right away.
    Flutter GPU may sample a texture that nothing wrote yet and the tracked layout of Impeller then disagreed with the
    image.
- `0018-vulkan-cheaper-draws-submits.patch` (mcsm8) cuts the CPU cost of Vulkan. Bindings go to the pass without a
  `ShaderMetadata` copy each. A submit or a texture overwrite disposes the pools of the thread at most every 16 ms.
  Signalled fences are reset and reused. A pass skips pipeline, descriptor set, vertex and index buffer binds that it
  already holds. Graphics pipelines take uniform buffers as dynamic descriptors, up to 8 and a pass keeps every set it
  wrote by its writes. On an RTX 4060 Ti a bare draw went from 0.74 to 0.16 µs and a submit from 435 to 9 µs.
- `0019-impeller-text-shadow-cache-by-content.patch` (mcsm9) makes `Canvas::AttemptBlurredTextOptimization` key a
  blurred text by the content of the text frame, its stroke and its transform without the whole-pixel translation.
  Upstream keyed it by the heap address of the `TextFrame` and the scale of the transform and a frame then depended on
  the allocator and the frames before it.
- `0020-impellerc-uniform-blocks-storage-targets.patch` (mcsm9) changes `impeller/compiler` and
  `impeller/shader_bundle/shader_bundle.fbs`.
  - Metal and Vulkan shaders limit each uniform block to 64 KB, the constant buffer size of Direct3D 11. Upstream
    limited all blocks of a shader together to 6,208 bytes, a GLES budget that GLES keeps.
  - Bundles record storage buffers and storage images with name, Metal index, set, binding and read-only and the
    workgroup size of a compute shader. The new fields are at the end of `BackendShader` and older bundles keep their
    bytes.
  - A bundle entry may give its backends, as in `"targets": ["metal_desktop", "vulkan"]`. A vertex stage that writes
    `gl_Layer` needs `--metal-version=2.2` or later.
  - `samplerBuffer` and `imageBuffer` are recorded as texel buffers. The companion buffer of the image atomics of
    Metal takes an index after every uniform and storage buffer. Textures and samplers declared apart are recorded
    apart, with explicit Metal indices after the combined ones.
  - Single-file compiles define the `IMPELLER_TARGET_*` macro of the target as bundles do.
  - The options `"metal_preserve_invariance"`, `"metal_safe_math"` and `"spirv_optimize": false` apply per shader. The
    folds of spirv-opt are not IEEE-exact.
- `0021-impeller-s2-formats-layered-textures-compute.patch` (mcsm9) adds to Impeller on Metal and Vulkan. GLES refuses
  these features.
  - Every uncompressed format that Metal and Vulkan share, D16 and D32 float, BC2, BC4, BC5 signed and BC6H and 2x
    MSAA.
  - 2D arrays, 3D textures and cube arrays, uploaded per layer or depth slice. Texture views of a mip range and a layer
    range with `Context::McsmMakeTextureView`. Depth-only render targets and sampled depth, also multisampled.
  - The attachment slice `kMcsmAllLayers` attaches every layer and the vertex stage picks the layer of each primitive.
    Indirect draws and dispatches with `McsmSetIndirect` and storage images in compute passes.
  - Samplers with a comparison function, clamp-to-border, mirror-clamp-to-edge, LOD clamps and a LOD bias on Vulkan.
    Textures and samplers bind apart with `McsmBindSeparateTexture` and `McsmBindSeparateSampler`.
  - Texel buffers with `McsmBindTexelBuffer`, as texture-buffer views on Metal and texel buffer views on Vulkan.
  - `ShaderLibrary::McsmRegisterFunction` compiles source with preserved invariance and safe math when the bundle asks.
  - Half, normalized and packed vertex formats and step rates per instance.
  - Copies between mip levels and slices and to buffers with `BlitPass::McsmCopyTextureToTexture` and
    `McsmCopyTextureToBuffer`. Mip generation on Vulkan covers every layer.
  - On Vulkan, compute passes move images to the layouts they read them in and storage images back to shader-read.
    Compute writes are ordered before every later stage. Sampled depth textures end their pass shader-read. The device
    of the embedder enables the features that these need where the GPU has them.
- `0022-gpu-layered-textures-storage-compute.patch` (mcsm9) is the Flutter GPU side of 0021 in `lib/gpu`, with layered
  textures and views, storage buffers, indirect draws, whole sampler states, compute pipelines and passes, copies, mip
  generation, texel buffers and separate textures and samplers. A slice of -1 attaches every layer. A D16 or D32 float
  texture attaches as depth only. Feature bit 2048 on Metal and Vulkan.
- `0023-impellerc-subpass-inputs-metal.patch` (mcsm10) gives a subpass input no explicit Metal texture index. With
  0020 the framebuffer blend shaders read the wrong colour attachment and their pipelines failed to build.
- `0024-impeller-unused-bindings-srgb-views-vulkan-bindings.patch` (mcsm10) changes `impeller/core` and
  `impeller/renderer/backend`.
  - The Metal binding caches take a bind at index 0xFFFFFFFF as a no-op. A resource that a stage declares and does not
    read has that index and binding it crashed the AGX driver.
  - A texture view may take the sRGB twin format of its texture, for 8-bit RGBA or BGRA, on Metal and Vulkan. On
    Vulkan 8-bit colour render targets are created mutable-format.
  - A Vulkan pipeline takes 128 bindings and descriptor pools 256 storage buffers.
- `0025-gpu-leaf-indirect-binding-resend-srgb-views.patch` (mcsm10) changes `lib/gpu`. A vertex stage without inputs
  loads. Storage buffers, texel buffers and separate textures and samplers go to the Metal encoder only when they
  changed or another binding took their index. `RenderPass_McsmDrawIndirectCached` is a leaf call that returns 2 when
  the pass has no pipeline yet. `Texture_McsmInitializeViewFormat` makes a view in the sRGB twin of the parent. Feature
  bit 4096 on Metal and Vulkan.
- `0026-impellerc-gpu-unused-resources.patch` (mcsm10) marks a resource that its stage does not read as `mcsm_unused`
  in the bundle. The field is written only when true and other bundles keep their bytes. Flutter GPU leaves such a
  resource out of the descriptor layout of the pipeline and binds it as a no-op on every backend. On Vulkan its binding
  took the place of the first resource of the other stage before.
- `0027-profile-heap-sample-traces-flag.patch` changes `shell/common/switches.cc` and
  `FlutterVSyncWaiter.mm`. Profile builds accept `--heap_sample_traces` and profile and release builds
  `--scavenge_census`, as Dart flags. macOS profile builds compile on the macOS 27 SDK. Release builds are unchanged.
- `dart/0001-vm-heap-sample-traces.patch` changes `runtime/vm/object.cc` of the Dart SDK.
  `--heap_sample_traces=<bytes>` records about one allocation per that many bytes as a profiler allocation trace with
  its Dart stack. With `--no-inline-alloc` and AOT code compiled with it, every allocation passes the check, and
  `getAllocationTraces` gives allocation by call site weighted by bytes. `--scavenge_census=<n>` prints, every n young
  collections, the bytes that they copied and promoted per class. Both are compiled out of release builds.
- `0028-gpu-detach-gc-idle.patch` (mcsm11) changes `lib/gpu/context`. `InternalFlutterGpu_McsmDetach(wrapper)` detaches
  a Flutter GPU wrapper from its native object at once and the wrapper can be initialized again.
  `InternalFlutterGpu_McsmGcIdle(budget µs, min bytes, max bytes)` calls `Dart_McsmIdle`. Feature bit 8192 on every
  backend.
- `dart/0002-vm-mcsm-idle.patch` (mcsm11) adds `Dart_McsmIdle(deadline, min_new_bytes, max_new_bytes)` to the Dart SDK,
  an idle point for the embedder in place of `Dart_NotifyIdle`. A young collection runs when new space holds the
  minimum and the estimate of the VM ends by the deadline, or when new space holds the maximum. A finished mark is
  finalized and a mark starts only at the soft threshold. No idle compaction runs and the page cache is kept. While
  such calls arrive, one in the last 100 ms, a finished mark waits for the next call. A VM whose embedder does not call
  it behaves as before.
- `0029-gpu-old-space-heap-figures.patch` (prismarine1) adds `InternalFlutterGpu_McsmOldSpace(request)` and
  `InternalFlutterGpu_McsmHeap(which)` to `lib/gpu/context`, both through `Dart_McsmOldSpace`, with feature bit 16384.
  A request of 1 starts an old-space mark now and 2 runs a young collection and a mark-compact with the page cache of
  the VM emptied. The heap figures are the old space used, its capacity and external size and the new space used and
  its capacity, in bytes.
- `dart/0003-vm-mcsm-old-space.patch` (prismarine1) adds `Dart_McsmOldSpace(request, figures)` to the Dart SDK. The VM does not
  compact on its own while the incremental compactor is on. That compactor moves at most a quarter of new space per
  mark, only from pages at most half full and the old space keeps the pages that its fragmentation holds.
- `0030-gpu-prismarine-names.patch` (prismarine1) gives the exports of Flutter GPU their prismarine names. Each
  `InternalFlutterGpu_Mcsm*` and `InternalFlutterGpu_<class>_Mcsm*` export of the patches above is
  `InternalFlutterGpu_Prismarine*` and `InternalFlutterGpu_<class>_Prismarine*`, such as
  `InternalFlutterGpu_PrismarineFeatures`, with the same feature bits. The Linux and Windows embedders read
  `PRISMARINE_RENDERER` and then `MCSM_RENDERER` and the Linux compositor reads `PRISMARINE_VK_DUMP`. The C++ names
  inside the engine keep their forms.
- `dart/0004-vm-prismarine-names.patch` (prismarine1) renames `Dart_McsmIdle` and `Dart_McsmOldSpace` to
  `Dart_PrismarineIdle` and `Dart_PrismarineOldSpace`.

## Checks of the current release

These checks ran on release prismarine1.

- gpu_smoke passes every check on Metal from the fetched macOS arm64 archive and on Vulkan on an RTX 4060 Ti under Linux
  from the fetched Linux x64 archive. The checks of prismarine1 read the heap figures, start a mark and compact the old
  space, which falls from 69 MB to 37 MB of capacity after 64 MB of small objects with every other one dropped.
- The Windows archives are built in a VM, fetched there and checked for the exports. gpu_smoke builds on them. It ran on
  no Windows machine with Vulkan for this release. The VM has no Vulkan device and on its ANGLE fallback gpu_smoke stops
  at the `ScreenCopy` of `prismarine_scene`, which has no GLES shaders. On release mcsm11 the checks of release 11
  passed on Vulkan and on ANGLE on an Intel UHD 620.
- A scene-like draw in gpu_smoke, with 2 vertex buffers, 2 uniform blocks, 3 textures and cull and winding per draw,
  costs 2.0 µs on the stock engine and about 0.6 µs patched on an M2 Pro. A bare draw costs 0.07 µs.
- macOS x64, Linux arm64 and Windows arm64 are built, packed and checksummed only, with no machine to run them.

## Reference

| Platform | Backend | Embedder |
|---|---|---|
| macOS | Metal | |
| Windows | Vulkan where it works, else GLES through ANGLE on Direct3D 11 | `windows/compositor_vulkan`, `windows/egl` |
| Linux | Vulkan where it works, else GLES or GL | the GTK embedder with `fl_compositor_vulkan` |

The cache of compiled shaders across launches is the precompiled `.metallib` of a bundle on macOS, with patch 0004.
On Windows it is the ANGLE program cache of patch 0005 and the Vulkan pipeline cache. On Linux Mesa and NVIDIA keep
their own disk caches.

| Target | Built on | gn | Out dir | Size | First build |
|---|---|---|---|---|---|
| macOS arm64 | a Mac, `build.sh build` | `--mac-cpu=arm64` | `host_release_arm64` | 4.6 GB | about 1 h |
| macOS x86_64 | a Mac, `PRISMARINE_ENGINE_CPU=x64 build.sh build` | `--mac-cpu=x64` | `host_release` | 2.6 GB without `obj/` | 13 min at 6 jobs |
| Linux x64 | Linux x64, `linux.sh build` | the host | `host_release` | 0.7 GB | 10 min at 10 jobs |
| Linux arm64 | Linux x64, cross-built with the Debian sysroot | `--target-os=linux --linux-cpu=arm64` | `linux_release_arm64` | 0.9 GB | 12.5 min |
| Windows x64 | Windows, `windows.ps1` | the host | `host_release` | 2.5 GB | 23 min at 10 jobs |
| Windows arm64 | Windows, cross-built | `--windows-cpu arm64` | `host_release_arm64` | 3.6 GB | 35 min |

The tests of the Linux x64 debug test build, `out/host_debug_unopt_tests` on SwiftShader, are these.

- `impeller_unittests --gtest_filter=*/Vulkan:-*Playground*` under Xvfb with the validation layers gives 711 passes, 21
  skips and no failures.
- In `gpu_unittests` the RenderPass suite and the ShaderLibrary suite pass. The CommandBuffer suite aborts in debug
  builds, since its test puts a ref-counted `CommandBuffer` on the stack. That is an upstream test bug in files that the
  patches do not touch.
