# Building

This page takes you from a fresh machine to an app that runs on the patched engine. You set up the toolchain, fetch a
release of the engine or build the engine from its patches and then build the app. The sample app in
`apps/prismarine_sample` is the example throughout.

## The toolchain

You need the Flutter SDK, Rust, CMake and a C compiler. The Flutter SDK must be 3.47.7, the version of the engine
patches. Clone it at its tag.

    git clone --branch 3.47.7 https://github.com/flutter/flutter.git ~/flutter

Each platform needs its own compiler and build tools, which Flutter uses for the app's native runner. The build hooks of
`prismarine_pad` and `prismarine_audio_out` also compile Rust crates, and `prismarine_pad` builds SDL with CMake and a
C compiler.

- On macOS, install Xcode 27 with its command-line tools and CMake, for example with `brew install cmake`.
- On Ubuntu, install `git curl unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
  libasound2-dev` with `sudo apt install`. The ALSA headers in `libasound2-dev` are for the audio output.
- On Windows, install Git and Visual Studio 2022 with the workload "Desktop development with C++". The workload brings
  the MSVC compiler and CMake.

Install Rust with rustup. On Windows, run `rustup-init.exe` from [rustup.rs](https://rustup.rs) and keep its MSVC
toolchain. Keep the default folders of rustup, `~/.rustup` and `~/.cargo`, since a build hook does not read
`RUSTUP_HOME` or `CARGO_HOME`.

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    rustup target add aarch64-apple-darwin x86_64-apple-darwin    # macOS only

A machine has one Flutter SDK, one pub cache and one engine directory for every repository on it, in `~/.prismarine`.
Link your Flutter SDK there once. `tools/toolchain/env.sh` reads the three folders, puts the Flutter SDK first on your
`PATH` and exports the pub cache. Source it in every bash or zsh shell that builds, tests or fetches.

    mkdir -p ~/.prismarine/pub-cache
    ln -s ~/flutter ~/.prismarine/flutter
    source tools/toolchain/env.sh

`PRISMARINE_FLUTTER`, `PRISMARINE_PUB_CACHE` and `PRISMARINE_ENGINE_DIR` move the three folders. The [toolchain
README](../tools/toolchain/README.md) lists the details. Windows has no form of `env.sh`. Put the `bin` folder of the
Flutter SDK on your `PATH` there.

`dart pub get` at the root of the checkout resolves the pub workspace, which holds the pure-Dart packages and the
lints. The Flutter packages `prismarine_render`, `prismarine_scene`, `prismarine_loop` and `prismarine_debug`, the
sample app and gpu_smoke are outside the workspace. Run `flutter pub get` in the directory of each one that you use.

    dart pub get
    (cd packages/prismarine_render && flutter pub get)

## A release of the engine

The patched engine is released as archives on the GitHub releases of the prismarine repository.
`third_party/flutter_engine/RELEASE` gives the release that your checkout needs, such as
`engine-deb287481e3c-prismarine1`. A release holds one archive `prismarine-engine-<target>.tar.xz` with its `.sha256`
file for each of the targets `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64` and
`windows-arm64`. It also holds `SHA256SUMS` with the checksums of all archives.

`third_party/flutter_engine/fetch.sh` downloads the archive of your machine with the GitHub CLI `gh`, checks its
SHA-256 and unpacks it into `~/.prismarine/engine/<target>`. The repository is private. You need `gh` logged in with
`gh auth login` to an account that can read it, or a token with read access to the repository in `GH_TOKEN`. Run the
commands from the root of your checkout.

    source tools/toolchain/env.sh
    export PRISMARINE_ENGINE_REPO=<owner>/prismarine
    third_party/flutter_engine/fetch.sh

| Setting | Meaning |
|---|---|
| `PRISMARINE_ENGINE_REPO` | The repository of the releases, as owner and name. Without it the script reads the value from a file `private/config/*.env` above the checkout. |
| `PRISMARINE_ENGINE_DIR` | The engine directory, `~/.prismarine/engine` by default. Every repository on the machine shares it. |
| `PRISMARINE_FLUTTER` | The Flutter SDK, by default the `flutter` on your `PATH`. |
| `PRISMARINE_ENGINE_ARCHIVE` | An archive that you downloaded, with its `.sha256` file beside it. The script unpacks it in place of a download. |

`fetch.sh macos-x64` or another target fetches the engine of another machine. On Windows,
`powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\fetch.ps1` fetches into
`%USERPROFILE%\.prismarine\engine`. The Windows script is not checked against a published release.

You can check an archive yourself. Download it with `SHA256SUMS` and compare the checksums, with `sha256sum` in place
of `shasum -a 256` on Linux.

    gh release download engine-deb287481e3c-prismarine1 -R "$PRISMARINE_ENGINE_REPO" \
      -p SHA256SUMS -p prismarine-engine-macos-arm64.tar.xz
    shasum -a 256 -c --ignore-missing SHA256SUMS

Source `tools/toolchain/env.sh` again after a fetch. It finds the engine of your machine in the engine directory,
sets the flags of a release `flutter build` in the array `prismarine_engine_args` and exports `PRISMARINE_IMPELLERC`,
the shader compiler of the engine. The array is empty without a patched engine and the build then runs on the stock
engine of Flutter, slower but with the same frames.

The commands of this section ran against release prismarine1 on macOS 27.2 on an Apple M2 Pro and on Ubuntu 26.04 on
x86-64.

## The engine from its patches

You can build the engine yourself from the patches in `third_party/flutter_engine/patches`. A build checks out
Flutter at the engine revision, applies the patches and fetches the dependencies of the engine with `gclient` of
Chromium's depot_tools. It then builds only the release targets that the Flutter tool reads. The first build takes
about an hour and several GB of disk on each machine.

| Platform | Script | Out dirs |
|---|---|---|
| macOS | `third_party/flutter_engine/build.sh all`, with `PRISMARINE_ENGINE_CPU=x64` for an Intel engine | `host_release_arm64`, `host_release` |
| Linux | `third_party/flutter_engine/linux.sh setup`, then `linux.sh build` | `host_release` for x64, `linux_release_arm64` for arm64 |
| Windows | `windows-toolchain.ps1` for the tools, then `windows.ps1 -EngineDir <dir>` | `host_release` for x64, `host_release_arm64` for arm64 |

The sources and the out dirs are in `<engine dir>/flutter`. `env.sh` takes a fetched engine before a built one. A
machine that holds the tree of the previous release builds the next release incrementally in a few minutes. Apply only
the new patches, with `git am <patch>` in `<engine dir>/flutter` and `git apply <patch>` for a new Dart patch in
`engine/src/flutter/third_party/dart`. Then run the build step alone, `build.sh build` on macOS or `linux.sh build` on
Linux. Do not run the setup again on a machine that has the tree. [The engine
README](../third_party/flutter_engine/README.md) lists the requirements of each platform, every patch, the packaging
of a release and its publishing.

## Apps on the engine

A release build of an app takes the flags in `prismarine_engine_args`. Debug builds run on the stock engine. The sample
app needs the model and its shaders. `tool/fetch.dart` downloads Intel's Sponza and prepares it in
`~/.prismarine/sample`, or in `%LOCALAPPDATA%\prismarine\sample` on Windows. The scene takes about 0.6 GB on disk.
`tool/shaders.sh` builds the shaders with the impellerc of the engine. [The sample
README](../apps/prismarine_sample/README.md) lists its options.

On macOS the commands build the app and start it.

    source tools/toolchain/env.sh
    cd apps/prismarine_sample
    flutter pub get
    dart tool/fetch.dart
    tool/shaders.sh "$PRISMARINE_IMPELLERC"
    flutter build macos --release "${prismarine_engine_args[@]}"
    build/macos/Build/Products/Release/prismarine_sample.app/Contents/MacOS/prismarine_sample

On Linux the same commands take `flutter build linux` and start
`build/linux/x64/release/bundle/prismarine_sample`, which runs with Vulkan.

    source tools/toolchain/env.sh
    cd apps/prismarine_sample
    flutter pub get
    dart tool/fetch.dart
    tool/shaders.sh "$PRISMARINE_IMPELLERC"
    flutter build linux --release "${prismarine_engine_args[@]}"
    build/linux/x64/release/bundle/prismarine_sample

On Windows the commands are for PowerShell on an x64 machine and build the app into
`build\windows\x64\runner\Release\prismarine_sample.exe`. `tool/shaders.sh` is a bash script. On Windows the build of
the shaders runs its Dart tool directly. These steps are not checked on a Windows machine. The build stopped in the
build of SDL for `prismarine_pad`, whose file paths are longer than MSBuild accepts.

    cd apps\prismarine_sample
    flutter pub get
    dart tool\fetch.dart
    $E = "$env:USERPROFILE\.prismarine\engine\windows-x64\src"
    dart ..\..\packages\prismarine_pbr\tool\build_shaders.dart shaders_generated --impellerc=$E\out\host_release\impellerc.exe
    flutter build windows --release --local-engine-src-path=$E `
      --local-engine=host_release --local-engine-host=host_release

Run the tests of a package in its directory, `dart test` for a pure-Dart package and `flutter test` for a Flutter
package. The first test run of `prismarine_pad` or `prismarine_audio_out` builds its Rust crate and SDL, which takes
about a minute.

    cd packages/prismarine_pad
    dart test
