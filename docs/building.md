# Building

This page takes you from a fresh computer to an app that runs on the patched engine. You set up the toolchain, fetch a
release of the engine or build the engine from its patches and then build the app. The sample app in
`apps/prismarine_sample` is the example throughout.

## Setting up toolchain

You need the Flutter SDK, Rust, CMake and a C compiler. The Flutter SDK must be 3.47.7, the version of the engine
patches. Clone it at its tag.

```sh
git clone --branch 3.47.7 https://github.com/flutter/flutter.git ~/flutter
```

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

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin    # macOS only
```

`tools/toolchain/env.sh` sets up a shell for prismarine. It looks for the Flutter SDK at `~/.prismarine/flutter`, keeps
the pub cache in `~/.prismarine/pub-cache` and the engine in `~/.prismarine/engine`, which all your prismarine
checkouts share. Point `~/.prismarine/flutter` at the SDK you cloned with a symbolic link. Then source
`env.sh` in every bash or zsh shell that builds, tests or fetches; it puts that Flutter first on your `PATH`.

```sh
mkdir -p ~/.prismarine/pub-cache
ln -s ~/flutter ~/.prismarine/flutter
source tools/toolchain/env.sh
```

To keep any of the three folders elsewhere, set `PRISMARINE_FLUTTER`, `PRISMARINE_PUB_CACHE` or
`PRISMARINE_ENGINE_DIR` to its path before you source `env.sh`. The [toolchain
README](../tools/toolchain/README.md) lists the details.

`env.sh` is for bash and zsh only. On Windows you set up the same things yourself. Add the `bin` folder of your
Flutter SDK to `PATH`. Set `PRISMARINE_ENGINE_DIR` if the engine should not be in
`%USERPROFILE%\.prismarine\engine`.

`dart pub get` at the root of the checkout resolves the pub workspace, which holds the pure-Dart packages and the
lints. The Flutter packages `prismarine_render`, `prismarine_scene`, `prismarine_loop` and `prismarine_debug`, the
sample app and gpu_smoke are outside the workspace. Run `flutter pub get` in the directory of each one that you use.

```sh
dart pub get
(cd packages/prismarine_render && flutter pub get)
```

## Using the prebuilt engine

The patched engine is released as archives on the GitHub releases of the prismarine repository. Each version of
prismarine works with one engine release. The file `third_party/flutter_engine/RELEASE` holds its name, for example
`engine-deb287481e3c-prismarine1`. The fetch scripts read that file themselves.

A release holds one archive `prismarine-engine-<target>.tar.xz` with its `.sha256` file for each of the targets
`macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64` and `windows-arm64`. It also holds
`SHA256SUMS` with the checksums of all archives.

`third_party/flutter_engine/fetch.sh` downloads the archive for your computer with the GitHub CLI `gh`, checks its
SHA-256 and unpacks it into `~/.prismarine/engine/<target>`. `gh` must be logged in, with
`gh auth login` or a token in `GH_TOKEN`. Run the commands from the root of your checkout.

```sh
source tools/toolchain/env.sh
export PRISMARINE_ENGINE_REPO=<owner>/prismarine
third_party/flutter_engine/fetch.sh
```

`fetch.sh` picks the target of your computer. To fetch the engine for another target, give the target as its
argument, for example `fetch.sh macos-x64`.

On Windows, run `powershell -ExecutionPolicy Bypass -File third_party\flutter_engine\fetch.ps1`. It fetches into
`%USERPROFILE%\.prismarine\engine`. The Windows script is not checked against a published release yet.

You can check an archive yourself. Download it with `SHA256SUMS` and compare the checksums, with `sha256sum` in place
of `shasum -a 256` on Linux.

```sh
gh release download engine-deb287481e3c-prismarine1 -R "$PRISMARINE_ENGINE_REPO" \
  -p SHA256SUMS -p prismarine-engine-macos-arm64.tar.xz
shasum -a 256 -c --ignore-missing SHA256SUMS
```

After a fetch, source `tools/toolchain/env.sh` again to build with the new engine. It sets `prismarine_engine_args`,
which you pass to `flutter build`, and `PRISMARINE_IMPELLERC`, the shader compiler of the engine. Without a fetched
engine, `flutter build` uses Flutter's own engine, which is slower.

## Patching and building the engine from stratch

You can build the engine yourself from the patches in `third_party/flutter_engine/patches`. A build checks out
Flutter at the engine revision, applies the patches and fetches the dependencies of the engine. The first build takes
about an hour and several GB of disk.

| Platform | Script | Out dirs |
|---|---|---|
| macOS | `third_party/flutter_engine/build.sh all`, with `PRISMARINE_ENGINE_CPU=x64` for an Intel engine | `host_release_arm64`, `host_release` |
| Linux | `third_party/flutter_engine/linux.sh setup`, then `linux.sh build` | `host_release` for x64, `linux_release_arm64` for arm64 |
| Windows | `windows-toolchain.ps1` for the tools, then `windows.ps1 -EngineDir <dir>` | `host_release` for x64, `host_release_arm64` for arm64 |

The sources and the out dirs are in `<engine dir>/flutter`. `env.sh` takes a fetched engine before a built one. Once you
have built one release, the next one builds incrementally in a few minutes. Apply only the new patches, with `git am
<patch>` in `<engine dir>/flutter` and `git apply <patch>` for a new Dart patch in
`engine/src/flutter/third_party/dart`. Then run the build step alone, `build.sh build` on macOS or `linux.sh build` on
Linux. Do not run the setup again once you have the tree. [The engine README](../third_party/flutter_engine/README.md)
lists the requirements of each platform, every patch, the packaging of a release and its publishing.

## Running sample app

To build an app on the patched engine, build it in release mode and pass `prismarine_engine_args` to `flutter build`.
Debug builds always use Flutter's own engine.

The sample app needs two things before its first build. `tool/fetch.dart` downloads Intel's Sponza and prepares it in
`~/.prismarine/sample`, or in `%LOCALAPPDATA%\prismarine\sample` on Windows; the prepared scene takes about 0.6 GB.
`tool/shaders.sh` compiles the sample's shaders with the shader compiler of the engine. The options of the sample are in
[its README](../apps/prismarine_sample/README.md).

On macOS the commands build the app and start it.

```sh
source tools/toolchain/env.sh
cd apps/prismarine_sample
flutter pub get
dart tool/fetch.dart
tool/shaders.sh "$PRISMARINE_IMPELLERC"
flutter build macos --release "${prismarine_engine_args[@]}"
build/macos/Build/Products/Release/prismarine_sample.app/Contents/MacOS/prismarine_sample
```

On Linux the same commands take `flutter build linux` and start
`build/linux/x64/release/bundle/prismarine_sample`, which runs with Vulkan.

```sh
source tools/toolchain/env.sh
cd apps/prismarine_sample
flutter pub get
dart tool/fetch.dart
tool/shaders.sh "$PRISMARINE_IMPELLERC"
flutter build linux --release "${prismarine_engine_args[@]}"
build/linux/x64/release/bundle/prismarine_sample
```

On Windows the commands are for PowerShell on an x64 PC and build the app into
`build\windows\x64\runner\Release\prismarine_sample.exe`. `tool/shaders.sh` is a bash script.

```powershell
cd apps\prismarine_sample
flutter pub get
dart tool\fetch.dart
$E = "$env:USERPROFILE\.prismarine\engine\windows-x64\src"
dart ..\..\packages\prismarine_pbr\tool\build_shaders.dart shaders_generated --impellerc=$E\out\host_release\impellerc.exe
flutter build windows --release --local-engine-src-path=$E `
  --local-engine=host_release --local-engine-host=host_release
```
