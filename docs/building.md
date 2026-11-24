# Building

This page takes you from a fresh computer to the sample app running on the patched engine. The `prismarine` command
does every step. It checks your tools, fetches the engine, cooks the shaders and assets of an app, builds the app and
starts it. The sample app in `apps/prismarine_sample` is the example throughout.

## Installing the tools

You need the Flutter SDK 3.47.7, Rust, CMake, git and the compiler of your platform. The `prismarine` command looks for
the Flutter SDK in `~/.prismarine/flutter` first. Clone it there at its tag.

```sh
git clone --branch 3.47.7 https://github.com/flutter/flutter.git ~/.prismarine/flutter
```

On macOS, install Xcode 27 from the App Store. Then install CMake and the Metal compiler of Xcode.

```sh
brew install cmake
xcodebuild -downloadComponent MetalToolchain
```

On Ubuntu, install these packages.

```sh
sudo apt install git curl xz-utils clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libasound2-dev
```

On Windows, install Git and Visual Studio 2022 with the workload "Desktop development with C++". The workload includes
the MSVC compiler and CMake.

Install Rust with rustup into its default folders, `~/.rustup` and `~/.cargo`. Build hooks do not receive
`RUSTUP_HOME` or `CARGO_HOME`, so other folders do not work. On macOS and Linux, run the installer of rustup.

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

On Windows, run `rustup-init.exe` from [rustup.rs](https://rustup.rs) and keep its MSVC toolchain. On macOS, also add
the Rust targets of both CPUs of the Mac.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

prismarine downloads the engine from its GitHub releases. The download needs the GitHub CLI, `gh`, logged in with
`gh auth login` or with a token in `GH_TOKEN`. Set `PRISMARINE_ENGINE_REPO` to the repository of the releases in the
form `<owner>/<name>`.

## Putting prismarine on your PATH

The `bin` folder of your checkout holds the command, `bin/prismarine` for macOS and Linux and `bin\prismarine.bat` for
Windows. Add this line to `~/.zshrc` or `~/.bashrc`, with the path of your checkout.

```sh
export PATH="$HOME/prismarine/bin:$PATH"
```

On Windows, add `<checkout>\bin` to the `Path` of your user in the settings of the environment variables. The batch file
runs in `cmd` and in PowerShell. Windows needs no bash.

The first run resolves the packages of the checkout and compiles the command, which takes a few seconds.

## Checking your computer

`prismarine doctor` lists every problem of your tools, the engine and the app at once, each with the command that fixes
it. Run it in your checkout.

```sh
prismarine doctor
```

## Running the sample

`prismarine run` builds an app and starts it. It checks the tools, fetches the engine, cooks the shaders, runs the
asset steps of the app, builds it in release mode and starts it. A step that is current is skipped. Each step prints
one line with its result and time.

The sample's `prismarine.yaml` lists its shaders and its one asset step, which downloads and prepares Sponza. Run it
from the root of your checkout:

```sh
prismarine run --app=apps/prismarine_sample
```

The first run downloads about 2.4 GB of Sponza and prepares it in `~/.prismarine/sample`, or in
`%LOCALAPPDATA%\prismarine\sample` on Windows, which takes a few minutes. Set `PRISMARINE_SAMPLE_DATA` to keep the
scene elsewhere. The arguments after `--` go to the app:

```sh
prismarine run --app=apps/prismarine_sample -- --gi=high
```

The options of the sample are in [its README](../apps/prismarine_sample/README.md).

A failed step prints its cause, the command that fixes it and the log of its tool. `--verbose` shows the output of
every tool as it runs.

## Your own app

An app describes itself in `prismarine.yaml`, beside its `pubspec.yaml`: the engine release and the Flutter SDK that
it needs, the shaders that it cooks and its asset steps. The file of the sample asks for the first release, cooks the
shaders of `prismarine_pbr` and prepares Sponza.

```yaml
engine: engine-deb287481e3c-prismarine1
flutter: 3.47.7
shaders:
  pbr:
    package: prismarine_pbr
    programs: shaders/programs
    out: shaders_generated
    shard: 100
    impellerc-args: [--metal-version=2.3]
assets:
  sponza:
    run: [dart, tool/fetch.dart, '--out={out}']
    out: '{data}/sample'
    out-env: PRISMARINE_SAMPLE_DATA
    inputs: [tool/fetch.dart, tool/src, package:prismarine_assets]
    exists: [prepared/main/scene.gltf, prepared/curtains/scene.gltf]
```

| Key | Meaning |
|---|---|
| `engine` | The engine release that the app builds and runs on. It must equal the release of the prismarine that the app depends on, and the command stops with the fix when it does not |
| `flutter` | The version of the Flutter SDK that the app needs, which `prismarine doctor` checks |
| `shaders.<id>.programs` | A tree of shader programs, a folder for each effect such as `programs/Pbr/` with a `bodies` folder for the files that programs include |
| `shaders.<id>.manifest` | A shader bundle manifest of impellerc, in place of `programs` |
| `shaders.<id>.package` | The package that holds `programs` or `manifest`. Without it the path is relative to the app |
| `shaders.<id>.out` | The folder of the bundles and `records.json`, or the bundle file of a manifest |
| `shaders.<id>.backends` | The backends of the bundles, `metal` and `vulkan` by default |
| `shaders.<id>.shard` | The number of shaders in one bundle file, 25 by default |
| `shaders.<id>.impellerc-args` | Extra arguments for every impellerc run |
| `assets.<id>.run` | The command of the step, run in the folder of the app. `{out}` is its output folder |
| `assets.<id>.out` | The output folder. `{data}` is `~/.prismarine`, or `%LOCALAPPDATA%\prismarine` on Windows |
| `assets.<id>.out-env` | An environment variable that sets the output folder in place of `out` |
| `assets.<id>.inputs` | Files and folders of the app and `package:<name>` for the code of a package |
| `assets.<id>.exists` | Files that a complete output holds. An output folder that holds them counts as current, also when the command did not prepare it |

A step runs again only when one of its inputs changed. A plain `flutter build` also compiles the shaders when your app
has a build hook. Add `prismarine_cook` and `hooks` to the dependencies of your app and this file as
`hook/build.dart`.

```dart
import 'package:hooks/hooks.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

void main(List<String> args) async {
  await build(args, cookHook);
}
```

At its start, an app calls `requireEngine` of `prismarine_scene` with the features that its code needs, such as
`pbrEngineFeatures`. On the wrong engine it stops with one message that gives the fix.

## Commands

| Command | Effect |
|---|---|
| `prismarine run [<platform>]` | Builds the app in release mode on the patched engine and starts it |
| `prismarine build [<platform>]` | Builds the app without its asset steps, `--stock` on the engine of Flutter, `--debug` in debug mode, `--profile` in profile mode on a profile engine and `--universal` for both CPUs of a Mac |
| `prismarine cook [<app>]` | Cooks the shaders and runs the asset steps that are not current |
| `prismarine doctor [<app>]` | Lists every problem with its fix |
| `prismarine engine` | Fetches the engine of the release of the app |
| `prismarine env` | Prints the lines that set the Flutter SDK, the pub cache and the engine of the app in a shell, `--shell=powershell` for PowerShell |
| `prismarine flutter …`, `prismarine dart …` | Runs `flutter` or `dart` of the SDK with the pub cache of prismarine |

The platform is the one of your computer by default. The app is the nearest folder at or above the current one with a
`prismarine.yaml`, else the one app below it. Where several apps are below it, as at the root of the checkout, the
command lists them with the command for each. `--app=<folder>` gives the app. `prismarine <command> --help` lists the
options with examples.

| Variable | Effect |
|---|---|
| `PRISMARINE_FLUTTER` | The Flutter SDK, when it is not in `~/.prismarine/flutter` |
| `PRISMARINE_PUB_CACHE` | The pub cache, `~/.prismarine/pub-cache` when that folder exists |
| `PRISMARINE_ENGINE_DIR` | The engine folder, `~/.prismarine/engine` by default. Every checkout on your computer shares it |
| `PRISMARINE_ENGINE_REPO` | The repository of the engine releases, as `<owner>/<name>` |
| `PRISMARINE_ENGINE_ARCHIVE` | A downloaded engine archive with its `.sha256` beside it, unpacked in place of a download |

## The engine

Each version of prismarine works with one release of the patched engine and `third_party/flutter_engine/RELEASE` holds
its name, such as `engine-deb287481e3c-prismarine1`. `prismarine engine` downloads the archive of that release for
your computer, checks its SHA-256 and unpacks it into `~/.prismarine/engine/<target>`, such as
`~/.prismarine/engine/macos-arm64`. `prismarine build` and `run` do this themselves when the engine is missing.

A release holds an archive for each of `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64` and
`windows-arm64`, about 20 MB each, with `SHA256SUMS`.

## Building the engine from the patches

You can build the engine yourself from the patches in `third_party/flutter_engine/patches`. The sources take about
13 GB in `~/.prismarine/engine/flutter` and the first build takes about an hour. On Windows, first install the build
tools of the engine in an elevated PowerShell with `prismarine engine toolchain`.

```sh
prismarine engine setup
prismarine engine patch
prismarine engine build
```

`setup` clones depot_tools and Flutter at the engine revision of your SDK and fetches the sources of the engine.
`patch` applies the patches that the tree lacks and `build` builds the release out folder of your CPU, or of both CPUs
with `--cpu=both`. After a new patch, `patch` applies only that patch and `build` takes a few minutes. `prismarine
build` and `prismarine run` use the engine built from the patches when the engine folder holds no fetched engine of
the release. A fetched release has no profile engine. `prismarine engine build --mode=profile` builds one for
`prismarine build --profile`, which profiling tools such as the Dart VM's allocation profiler need.

`package` packs the out folders of your engine into archives, the form in which a release is fetched.

```sh
prismarine engine package --cpu=both --dest=~/engine-packages
```

[The engine README](../third_party/flutter_engine/README.md) lists every patch and the requirements of each platform.
