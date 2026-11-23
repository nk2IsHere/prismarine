<img alt="prismarine" src="docs/logo/lockup.png" height="96">

#

**prismarine** is a toolkit for making games with Flutter and Dart. It provides a renderer on Flutter GPU, a patched
Flutter engine and the parts that a real-time game needs around them, from worker threads to deterministic replay.
Every part runs on macOS, Linux and Windows.

## Packages

The README of each linked package gives its use, a short example and its platforms.

| Package | Contents |
|---|---|
| [`prismarine_frame`](packages/prismarine_frame/README.md) | Frame plans of passes, targets and buffers, with a codec that moves a plan between isolates |
| [`prismarine_render`](packages/prismarine_render/README.md) | The runner that records a frame plan on Flutter GPU and skips a pass whose inputs are unchanged |
| [`prismarine_scene`](packages/prismarine_scene/README.md) | A glTF importer, a scene-node layer and paced loading of assets |
| [`prismarine_shaders`](packages/prismarine_shaders/README.md) | Shader bundles for impellerc, a cache of compiled shaders and precompiled Metal libraries |
| [`prismarine_assets`](packages/prismarine_assets/README.md) | Readers and writers for glTF, KTX2 and PNG, with decoding of BC textures |
| [`prismarine_jobs`](packages/prismarine_jobs/README.md) | A pool of worker isolates with priorities and cancellation, thread roles per OS and a check of free memory |
| [`prismarine_kept`](packages/prismarine_kept/README.md) | Maps, sets and lists that keep their storage when cleared |
| [`prismarine_snap`](packages/prismarine_snap/README.md) | Binary snapshots of object graphs that preserve the references between objects |
| `prismarine_replay` | Recording of input, deterministic replay and a schedule of snapshots |
| [`prismarine_math`](packages/prismarine_math/README.md) | Maths functions that give the same bits on every OS |
| `prismarine_lua` | An embeddable Lua 5.2 for Dart |
| [`prismarine_audio`](packages/prismarine_audio/README.md) | Audio interfaces and an engine of events and buses |
| [`prismarine_audio_out`](packages/prismarine_audio_out/README.md) | Audio output, decoding of MP3 and Vorbis and a cache of decoded sounds |
| [`prismarine_pad`](packages/prismarine_pad/README.md) | Gamepads through SDL3 |
| [`prismarine_loop`](packages/prismarine_loop/README.md) | Frame pacing, GC pacing, a frame limiter, window focus, cursor capture and mouse look |
| [`prismarine_debug`](packages/prismarine_debug/README.md) | Frame history, a profiler per frame, a log of GPU passes, glitch capture and a debug panel |
| [`prismarine_cargo`](packages/prismarine_cargo/README.md) | A build hook that compiles the Rust crate of a package |

## Engine

The patched Flutter engine extends Flutter GPU with cheaper draws, retained draws, multiple render targets,
instancing, compute, texel buffers, texture arrays and 3D textures. It adds Vulkan for Linux and Windows. The Dart VM
gets collections at idle points of the frame and heap figures for the debug tools.

## Platforms

prismarine renders through Metal on macOS and through Vulkan on Linux and Windows. OpenGL ES is not supported.

| Platform | Graphics | Lowest tested version | Tested on |
|---|---|---|---|
| macOS | Metal | macOS 27.2 | Apple M2 Pro |
| Linux | Vulkan | Ubuntu 26.04 LTS | NVIDIA GeForce RTX 4060 Ti, driver 610 |
| Windows | Vulkan 1.1 | Windows 10 21H2 | Intel UHD Graphics 620 |

## Tools

| Tool | Purpose |
|---|---|
| [Allocation lint](tools/lint/README.md) | Finds code on the frame path that allocates memory |
| [Code checks](tools/lint/README.md) | Runs the analyzer, the formatters and file size checks and comments against a baseline |
| [Heap and allocation profiler](tools/profiler/README.md) | Compares heap snapshots and shows the places that allocate |
| [GPU smoke tool](tools/gpu_smoke/README.md) | Checks the Flutter GPU features of the engine on a machine |
| [Machine locks](tools/machine/README.md) | Share one machine between the heavy jobs and the timed runs of every repository on it |
| [Engine release scripts](third_party/flutter_engine/README.md) | Build, package and fetch the patched engine for each platform |

## Workspace setup

You need the Flutter SDK, the patched engine, Rust, CMake and a C compiler. The Flutter SDK must be 3.47.7, the version
of the engine patches. Clone it at its tag and put its `bin` folder on your `PATH`.

    git clone --branch 3.47.7 https://github.com/flutter/flutter.git ~/flutter
    export PATH=$HOME/flutter/bin:$PATH
    flutter --version

Each platform needs the tools of a Flutter desktop app. The build hooks of `prismarine_pad` and `prismarine_audio_out`
compile Rust crates. `prismarine_pad` also builds SDL with CMake and a C compiler.

- On macOS, install Xcode 27 with its command-line tools and CMake, for example with `brew install cmake`.
- On Ubuntu, install `git curl unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
  libasound2-dev` with `sudo apt install`. The ALSA headers in `libasound2-dev` are for the audio output.
- On Windows, install Git and Visual Studio 2022 with the workload "Desktop development with C++". The workload brings
  the MSVC compiler and CMake.

Install Rust with rustup. On Windows, run `rustup-init.exe` from [rustup.rs](https://rustup.rs) and keep its MSVC
toolchain. Keep the default folders of rustup, `~/.rustup` and `~/.cargo`, since a build hook does not get
`RUSTUP_HOME` or `CARGO_HOME`. A macOS app build compiles each crate for both CPUs of the Mac, which needs the standard
libraries of both targets.

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    rustup target add aarch64-apple-darwin x86_64-apple-darwin    # macOS only

### The patched engine

A release of the patched engine is a set of archives on GitHub, one for each platform and CPU. `fetch.sh` downloads the
archive of your machine with the GitHub CLI, checks it and unpacks it into the engine directory. `gh` must be logged in
to an account that can read the repository of the releases. `PRISMARINE_ENGINE_DIR` is the engine directory, which every
repository on the machine shares. `PRISMARINE_ENGINE_REPO` is the repository of the releases, as owner and name. Run the
script from the root of your checkout.

    export PRISMARINE_ENGINE_DIR=$HOME/prismarine-engine
    export PRISMARINE_ENGINE_REPO=<owner>/<name>
    third_party/flutter_engine/fetch.sh

On Windows, run `powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\fetch.ps1`. The script prints the
flags of `flutter build` for the engine at its end. You can also build the engine yourself, which takes about an hour on
each machine. [The engine README](third_party/flutter_engine/README.md) describes both ways. An app builds and runs on
the stock engine of Flutter too, slower but with the same frames.

### Dependencies

`dart pub get` at the root of the checkout resolves the pub workspace, which holds the pure-Dart packages and the lints.
The Flutter packages `prismarine_render`, `prismarine_scene`, `prismarine_loop` and `prismarine_debug`, the sample app
and gpu_smoke are outside the workspace. Run `flutter pub get` in the directory of each one that you use.

    dart pub get
    (cd packages/prismarine_render && flutter pub get)

### The private repo

The folder `private/` is ignored by git. It can hold a separate private repository with the privacy patterns and the
landing gate. You do not need it to build or test prismarine. Only the privacy check of the lints fails without it. The engine
scripts read `PRISMARINE_ENGINE_REPO` from a file `private/config/*.env` when the variable is not set.

## Building

Run the tests of a package in its directory, `dart test` for a pure-Dart package and `flutter test` for a Flutter
package. The first test run of `prismarine_pad` or `prismarine_audio_out` builds its Rust crate and SDL, which takes
about a minute.

    cd packages/prismarine_pad
    dart test

The sample app in `apps/prismarine_sample` is the example of an app build. A release build with the flags that
`fetch.sh` printed runs on the patched engine. A build without them runs on the stock engine. The steps below for macOS
ran on macOS 27.2 on an Apple M2 Pro and the steps for Linux on Ubuntu 26.04 on x86-64. The steps for Windows follow the
scripts of the engine and are not checked on a Windows machine.

### macOS

The commands build and start the app on an Apple silicon Mac. An Intel Mac takes `macos-x64` and `host_release` in place
of `macos-arm64` and `host_release_arm64`. The Intel form is not checked.

    cd apps/prismarine_sample
    flutter pub get
    E=$PRISMARINE_ENGINE_DIR/macos-arm64/src
    flutter build macos --release --local-engine-src-path=$E \
      --local-engine=host_release_arm64 --local-engine-host=host_release_arm64
    build/macos/Build/Products/Release/prismarine_sample.app/Contents/MacOS/prismarine_sample

### Linux

The commands build the app on an x86-64 machine into `build/linux/x64/release/bundle/prismarine_sample`. The Linux
runner of the app does not turn Flutter GPU on. The app starts with Vulkan and stops at its first call of Flutter GPU.

    cd apps/prismarine_sample
    flutter pub get
    E=$PRISMARINE_ENGINE_DIR/linux-x64/src
    flutter build linux --release --local-engine-src-path=$E \
      --local-engine=host_release --local-engine-host=host_release

### Windows

The commands are for PowerShell on an x64 machine and build the app into
`build\windows\x64\runner\Release\prismarine_sample.exe`. They are not checked on Windows. The Windows runner of the app
does not turn Flutter GPU on either.

    cd apps\prismarine_sample
    flutter pub get
    $E = "$env:PRISMARINE_ENGINE_DIR\windows-x64\src"
    flutter build windows --release --local-engine-src-path=$E `
      --local-engine=host_release --local-engine-host=host_release

## Licence

prismarine is licensed under the [BSD-3 licence](LICENSE).
<br>
Built with stochastic parrots and human.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo/flutter/built_with_flutter_white.svg">
  <img alt="Built with Flutter" src="docs/logo/flutter/built_with_flutter.svg" height="40">
</picture>

