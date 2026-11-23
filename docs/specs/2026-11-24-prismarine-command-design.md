# The prismarine command

This spec adds one command, `prismarine`, that checks the toolchain, fetches the engine, cooks the shaders and assets
of an app and builds and runs it. An app of prismarine takes five manual steps today, in a fixed order. A step in the
wrong order gives a broken app with a crash far from its cause.

1. `tools/toolchain/env.sh` is sourced.
2. The engine release of `third_party/flutter_engine/RELEASE` is fetched with `fetch.sh` or `fetch.ps1`.
3. The shaders of the app are built. The sample runs `tool/shaders.sh`, which runs `tool/build_shaders.dart` of
   `prismarine_pbr`.
4. The assets of the app are prepared. The sample runs `tool/fetch.dart`, which downloads Sponza and runs `prepareGltf`.
5. `flutter build <platform> --release` runs with `prismarine_engine_args`.

Two failures of this kind happened. An app built against an engine older than its flutter_gpu died on a null texture.
The vendored flutter_gpu probes the exports of the engine by name, and the engine of prismarine1 renamed them, so every
patched call took the stock path without a word. An app built before `tool/shaders.sh` ran stopped with "no shader
Pbr/gi_trace.comp". `flutter build` does not build the shaders of `shaders_generated/`, and the bundle there was older
than the code.

## Goals

- One command for every step on macOS, Linux and Windows: `doctor`, `engine`, `cook`, `build`, `run`, `env` and a
  pass-through for `flutter` and `dart`.
- A plain `flutter build` of a ported app cooks its shaders through a build hook. A stale shader bundle cannot reach an
  app.
- The cooking of an app is listed in its own file, `prismarine.yaml`. A cook step runs again only when the hash of its
  inputs changed.
- An app that starts on the wrong engine stops at once with one message that gives the fix.
- The sample is ported. Its README says `prismarine run macos`.
- Windows has no bash. The command does there what `env.sh` does in bash.

## Not in scope

- The installation of the Flutter SDK, Rust, Xcode, Visual Studio or packages of the OS. `doctor` gives the command
  for each one and the user runs it.
- The build of the engine from its patches. The engine scripts stay as they are.
- Data assets of the hooks of Dart. They need `flutter config --enable-dart-data-assets` on Flutter 3.47.7, which is
  experimental. The hook writes into the folder of the app like the hook of `prismarine_scene` does.
- mcsm. Its player, slicer and scripts stay as they are. The end of this spec lists what mcsm could take.

## Packages and launchers

| Part | Path | Contents |
|---|---|---|
| `prismarine_cook` | `packages/prismarine_cook` | The project file, the engine locator, the cook of shaders and of asset steps with their stamps, the build hook |
| `prismarine_cli` | `packages/prismarine_cli` | The commands, the toolchain checks of `doctor`, the runs of `flutter` |
| Launchers | `bin/prismarine`, `bin/prismarine.bat` | Find the Flutter SDK, resolve the workspace once and start the command |

Both packages are pure Dart and members of the pub workspace. The app depends on `prismarine_cook` for its hook. The
command depends on it for the same code.

The launchers follow the form of Flutter's own `bin/flutter`. A user puts `<checkout>/bin` on `PATH`. A launcher picks
the Flutter SDK from `PRISMARINE_FLUTTER`, then `~/.prismarine/flutter`, then the `flutter` on `PATH`. Without one it
prints the `git clone` of Flutter 3.47.7 into `~/.prismarine/flutter` and stops. It sets `PUB_CACHE` to
`PRISMARINE_PUB_CACHE` or to `~/.prismarine/pub-cache` when that folder exists. It runs `dart pub get` in the checkout
when `.dart_tool/package_config.json` is missing or older than `pubspec.lock`. It starts
`packages/prismarine_cli/bin/prismarine.dart` from a JIT snapshot in `.dart_tool/prismarine/`, made again when a source
of the command is newer. The bash launcher runs on macOS and Linux and the batch file in `cmd` and PowerShell.

`bin/prismarine.bat` replaces `env.sh` on Windows. `prismarine env --shell=powershell` prints the lines that set
`PATH`, `PUB_CACHE`, `PRISMARINE_ENGINE_DIR` and `PRISMARINE_IMPELLERC` in a PowerShell session.
`prismarine flutter <args>` and `prismarine dart <args>` run the tools of the SDK with the same environment. `env.sh`
stays for bash scripts, such as the landing gate.

## The project file

`prismarine.yaml` is in the folder of an app, beside `pubspec.yaml`. The sample has this file.

```yaml
shaders:
  pbr:
    package: prismarine_pbr
    programs: shaders/programs
    out: shaders_generated
    shard: 100
    impellerc-args: [--metal-version=2.3]
assets:
  sponza:
    run: [dart, tool/fetch.dart, --out={out}]
    out: '{data}/sample'
    out-env: PRISMARINE_SAMPLE_DATA
    inputs: [tool/fetch.dart, tool/src, package:prismarine_assets]
```

| Key | Meaning |
|---|---|
| `shaders.<id>.package` | The package whose folder holds `programs`. Without it the path is relative to the app |
| `shaders.<id>.programs` | A program tree of `prismarine_shaders`, a folder for each effect with a `bodies` folder for includes |
| `shaders.<id>.out` | The output folder in the app: `bundle/<backend>/<effect>.<n>.shaderbundle.gz`, `records.json` and the stamp |
| `shaders.<id>.backends` | The backends, `metal` and `vulkan` by default |
| `shaders.<id>.shard` | The entries per shard, 25 by default |
| `shaders.<id>.impellerc-args` | Extra arguments of every impellerc run |
| `assets.<id>.run` | The command of the step, run in the folder of the app. `{out}` becomes the output folder |
| `assets.<id>.out` | The output folder. `{data}` is `~/.prismarine` or `%LOCALAPPDATA%\prismarine` on Windows |
| `assets.<id>.out-env` | A variable that sets the output folder when it is set |
| `assets.<id>.inputs` | Files and folders of the app, and `package:<name>` for the `lib` folder of a package |

`records.json` holds the interface of every shader, as `shaderInterface` of `prismarine_shaders` reads it from the
source with its includes and its `#ifdef` blocks resolved. This code moves from `tool/build_shaders.dart` of
`prismarine_pbr` into `prismarine_shaders` as `programRecords`. The tool goes.

## Cooking

A shader entry cooks when the stamp `<out>/cook.json` is missing or holds another key. The key is a SHA-256 over the
cook version, the path and bytes of every file of the program tree, the settings of the entry, the bytes of impellerc
and the path, size and time of the Metal compiler. A cook writes the bundles and `records.json` first and the stamp
last. A failed cook leaves no stamp. The shard cache of `prismarine_shaders` in `~/.prismarine/cache/shaders` keeps
the shards. A cook after a change to one effect compiles only that effect's changed shards.

An asset step runs when its stamp, `cook-<id>.json` in its output folder, is missing or holds another key. The key
covers the command and the path and bytes of every file of its inputs. A step that fails leaves no stamp. A step that
someone deleted with its output folder runs again. The command runs asset steps. The build hook does not, since a step
can download gigabytes.

## The build hook

A ported app has `hook/build.dart`, which calls `cookHook` of `prismarine_cook`. Flutter runs the hooks of an app
before it bundles the assets, in `flutter build`, `flutter run` and `flutter test`. `cookHook` cooks every shader entry
of `prismarine.yaml` whose stamp is stale. It declares the project file, every file and folder of each program tree,
impellerc and each stamp as dependencies of the hook. A deleted output folder or a changed shader runs the hook again.

Flutter gives a hook a filtered environment with `HOME`, `PATH` and the temporary folders but without
`PRISMARINE_ENGINE_DIR`. The hook finds impellerc in this order.

1. `.dart_tool/prismarine/engine.json` of the app, which `prismarine build`, `run` and `cook` write with the engine
   in use.
2. The fetched engine of the release in `~/.prismarine/engine/<target>`, or `%USERPROFILE%\.prismarine\engine` on
   Windows.

Without an impellerc the hook fails with the fix, `prismarine engine`. A hook that has no `prismarine.yaml` does
nothing.

## The engine locator

The release that an app needs is in `RELEASE` beside the `flutter_gpu` that the app resolves. The locator reads the
root of `flutter_gpu` from `.dart_tool/package_config.json` of the app and takes `../flutter_engine/RELEASE` from
there. The vendored flutter_gpu and `RELEASE` are in the same commit of prismarine, also in a git dependency in the pub
cache. Outside an app, the locator takes `RELEASE` of the checkout of the command.

The engine folder is `PRISMARINE_ENGINE_DIR`, else `~/.prismarine/engine`, or `%USERPROFILE%\.prismarine\engine` on
Windows. The target follows the OS and CPU, such as `macos-arm64` or `windows-x64`. The locator takes, in this order:

1. The fetched engine `<engine dir>/<target>`, when `prismarine-engine.txt` there gives the release of the app.
2. A built engine `<engine dir>/flutter/engine/src/out/<out>`, when its engine library exports
   `InternalFlutterGpu_PrismarineFeatures`. The command then prints a line that the build uses an engine built from
   the patches and that it does not compare its patches with the release.

A fetched engine of another release is reported with its release and is not used. The out folder of a fetched engine
is the `out` of its `prismarine-engine.txt`. The engine library is `FlutterMacOS` in the xcframework,
`libflutter_linux_gtk.so` or `flutter_windows.dll`. A search of its bytes for the export finds it on every OS without
`nm` or `dumpbin`.

## The commands

| Command | Effect |
|---|---|
| `prismarine doctor [<app>]` | Checks the toolchain, the engine and, with an app, its packages and cook state. Prints each finding with its fix. Exits with 1 when one is a problem |
| `prismarine engine [--target=<t>] [--force]` | Fetches the release of the app or of the checkout through `fetch.sh` or `fetch.ps1`, or says why it cannot |
| `prismarine cook [<app>] [--shaders] [--assets]` | Runs `flutter pub get` when needed and cooks what is stale |
| `prismarine build [<platform>] [--app=<dir>] [--debug] [-- <flutter args>]` | Fetches a missing engine, cooks and runs `flutter build <platform> --release` with the engine flags |
| `prismarine run [<platform>] [--app=<dir>] [-- <app args>]` | Builds, then starts the built app with its arguments and returns its exit code |
| `prismarine env [--shell=sh\|powershell\|cmd]` | Prints the lines that set the toolchain in a shell |
| `prismarine flutter <args>`, `prismarine dart <args>` | Runs the tool of the SDK with the toolchain |

The platform is the OS of the computer by default. The app is the current folder by default and else the nearest
folder above it with a `prismarine.yaml`. `build` prints one line for each step, such as `engine: engine-…-prismarine1
in ~/.prismarine/engine/macos-arm64`, `cook pbr: 41 shaders, 39 from the cache` and the path of the app at the end. A
debug build runs on the engine of Flutter. `build --debug` says so in a line and passes no engine flags.

`run` starts the binary of the build: `build/macos/Build/Products/Release/<product>.app/Contents/MacOS/<product>`,
`build/linux/<arch>/release/bundle/<binary>` or `build\windows\<arch>\runner\Release\<binary>.exe`. The product name is
`PRODUCT_NAME` of `macos/Runner/Configs/AppInfo.xcconfig` and the binary name `BINARY_NAME` of the `CMakeLists.txt` of
the platform.

`engine` checks before the download that `gh` is installed, that it is logged in or `GH_TOKEN` is set and that the
release repository is known from `PRISMARINE_ENGINE_REPO` or `private/config/*.env`. Each missing part stops it with
its own message and fix.

## The checks of doctor

| Check | Problem when | Fix that doctor prints |
|---|---|---|
| Flutter SDK | missing, not 3.47.7, or its engine revision differs from the release | the clone at the tag into `~/.prismarine/flutter` |
| Rust | no `cargo` on `PATH` or in `~/.cargo/bin` | the rustup install |
| Rust targets | macOS lacks `aarch64-apple-darwin` or `x86_64-apple-darwin`; Windows lacks its MSVC target | `rustup target add …` |
| CMake | no `cmake`, on Windows also none in Visual Studio | `brew install cmake`, the apt line, or the C++ workload |
| Xcode | macOS without Xcode or without its Metal compiler | the Xcode install, `xcodebuild -downloadComponent MetalToolchain` |
| Linux packages | `clang`, `ninja`, `pkg-config`, or `gtk+-3.0`, `alsa` and `liblzma` through `pkg-config`, missing | the `apt install` line of the packages that are missing |
| Visual Studio | Windows without Visual Studio 2022 and its C++ tools, found with `vswhere` | the workload "Desktop development with C++" |
| git | missing | the install of git |
| Engine | no engine of the release | `prismarine engine` |
| Engine and SDK | the engine is for another engine revision than the Flutter SDK | the clone of the SDK at the tag |
| Release download | the engine is missing and `gh`, its login or the repository setting is missing | `gh auth login`, `PRISMARINE_ENGINE_REPO=<owner>/<name>` |
| App packages | `.dart_tool/package_config.json` is older than `pubspec.yaml` | `prismarine cook` |
| Cook state | a stamp is stale | `prismarine cook` |

## The check at app start

`prismarine_scene` gets `engine_check.dart` beside `gpuFeatures`. `prismarineEngineRelease` is the release of this
commit of prismarine, a constant that a test compares with `RELEASE`. `engineProblem(needs)` returns null when the
running engine has every feature bit of `needs` and else one message for the one case that happened.

| Case | Message |
|---|---|
| Flutter's own engine | The app runs on the engine of Flutter. It needs the patched engine `<release>`. Build it with `prismarine build`. |
| A patched engine without the prismarine exports | The app runs on a patched engine older than `<release>`. Run `prismarine engine` and build again with `prismarine build`. |
| Feature bits missing | The engine lacks `<features>` of release `<release>`. Run `prismarine engine` and build again with `prismarine build`. |

`requireEngine(needs)` throws `EngineMismatch` with that message. `prismarine_pbr` exports `pbrEngineFeatures`, the
bits of compute and of the added bindings. The sample calls `requireEngine(pbrEngineFeatures)` first in its load. It
shows the message in its window and prints it, and exits with 1 in a smoke or performance run. The runner of
`prismarine_render` does not check. mcsm runs it in tests on the engine of the Flutter tester.

`PbrAssets` fails a missing shader with the id and the fix, `prismarine cook`, in place of "no shader <id>".

## The sample

- `prismarine.yaml` lists the shaders of `prismarine_pbr` and the Sponza step.
- `hook/build.dart` calls `cookHook`. `pubspec.yaml` depends on `prismarine_cook` and `hooks`.
- `tool/shaders.sh` and `tool/build_shaders.dart` of `prismarine_pbr` go. The landing gate runs `bin/prismarine cook
  apps/prismarine_sample` in place of `tool/shaders.sh`.
- The message of `SampleDataMissing` gives `prismarine cook` as the fix.
- The README says `prismarine run macos`, with Linux and Windows in their own sentences.

`docs/building.md` starts with the command: put `bin` on `PATH`, run `prismarine doctor`, then `prismarine run`. The
manual steps stay on the page for an engine built from the patches. The README of the toolchain and its area page say
that the command covers `env.sh` on every OS.

## Checks

- Tests of `prismarine_cook` for the project file, the stamps, the order of the engine locator, the search for the
  export, the target of each OS and the hook's choice of impellerc. Tests of `prismarine_cli` for the arguments, the
  findings of doctor from faked tool outputs and the paths of the built app. The tests run on every OS.
- On macOS and on Linux in the container of the workstation, a fresh clone runs `prismarine run` from nothing to the
  sample, with only the Flutter SDK and the OS tools in place and an empty engine folder.
- A shader edited after a build is cooked by a plain `flutter build`. An app built against an engine of an older
  release stops with the message of the table above.
- Windows builds on VM 2 when the owner allows it.

## Use in mcsm

mcsm could take three parts later, each its own change in mcsm.

- `prismarine doctor` and `prismarine engine` in place of `tools/toolchain/fetch_engine.sh` and the engine checks of
  its `env.sh`.
- `requireEngine` at the start of the player, with the bits of its renderer.
- `prismarine build` for the player, after its build moves out of the mirror of `sync.sh`.
