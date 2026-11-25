# prismarine_cli

`prismarine_cli` is the `prismarine` command. It checks the toolchain, fetches and builds the patched engine, cooks the
shaders and assets of an app through [prismarine_cook](cook.md) and builds and runs the app on macOS, Linux and Windows.
[The build page](../building.md) is the guide for users. This page describes how the command works.

## Launchers

`bin/prismarine` for bash and `bin/prismarine.bat` for `cmd` and PowerShell start the command. A launcher finds the
Flutter SDK in `PRISMARINE_FLUTTER`, then `~/.prismarine/flutter`, then the `flutter` on `PATH` and prints the clone of
Flutter 3.47.7 without one. It sets `PUB_CACHE` to `PRISMARINE_PUB_CACHE` or to `~/.prismarine/pub-cache` when that
folder exists. It runs `dart pub get` in the checkout when its package config is missing and compiles the command into
`.dart_tool/prismarine/prismarine.dill` when that file is missing. The command compiles itself again and runs the new
kernel when a source of `prismarine_cli`, `prismarine_cook` or `prismarine_shaders` or `pubspec.lock` is newer than the
kernel. The new kernel runs with `PRISMARINE_REBUILT=1` and does not compile itself again. A warm start takes about
0.15 s.

The command takes the Flutter SDK of the Dart that runs it. It puts the `bin` folder of the SDK first on the `PATH` of
every tool it runs and sets `FLUTTER_ROOT` and `PUB_CACHE`. `prismarine env` prints the same settings for a shell, and
`prismarine flutter` and `prismarine dart` run the tools of the SDK with them. The engine lines of `prismarine env` are
for the release of the app: `--app`, else the app of the current folder, else the checkout of the command. They give
`PRISMARINE_IMPELLERC`, `PRISMARINE_ENGINE_ARGS` and, when a profile engine exists, `PRISMARINE_ENGINE_PROFILE_ARGS`.
The engine folder is given by its resolved path, as build caches store it.

## The app

A command works on the app in `--app`, else on the nearest folder at or above the current one with a
`prismarine.yaml`, else on the one app below the current folder. The search below goes three levels down and skips
hidden folders and `build` folders. Several apps below the current folder are listed, each with its command. At the
root of a prismarine checkout these are the sample and gpu_smoke.

## Steps

`build` and `run` run these steps in order. Each prints one line with its result and time. On a terminal the line of a
running step shows its time and the last line of its tool, or, once the tool prints a line
`progress: <done>/<total> <what>`, the last such line. The output of each tool goes to
`.dart_tool/prismarine/logs/<step>.log` of the app. `--verbose` also prints it while the tool runs. A failed step
prints its cause, the last lines of the tool, the path of its log and the command that fixes it. The command then
exits with 1.

| Step | Work | Skipped when |
|---|---|---|
| packages | `flutter pub get` in the app | the package config is newer than `pubspec.yaml` and `pubspec.lock` |
| toolchain | the checks of doctor for the toolchain, every problem listed at once | not skipped. It takes about 0.3 s |
| engine | finds the engine of the release of the app and fetches it when it is missing | the engine is in place |
| shaders | the shader entries of `prismarine.yaml` | their stamps are current |
| assets | the asset steps of `prismarine.yaml`, in `run` only | their stamps are current |
| build | `flutter build <platform> --release` with the engine flags | not skipped. Flutter skips the parts that are current |

`run` then starts the built binary with the arguments after `--` and returns its exit code. The binary is
`build/macos/Build/Products/Release/<PRODUCT_NAME>.app/Contents/MacOS/<PRODUCT_NAME>`,
`build/linux/<arch>/release/bundle/<BINARY_NAME>` or `build\windows\<arch>\runner\Release\<BINARY_NAME>.exe`, with the
names from `macos/Runner/Configs/AppInfo.xcconfig` and the `CMakeLists.txt` of the platform.

`build macos --universal` also fetches the engine of `macos-x64`, builds the app on each engine and merges the two
apps. `lipo` joins each pair of Mach-O files. The other files must be equal. The exceptions are
`NativeAssetsManifest.json`, which keeps the entries of both CPUs, the signatures and the `Info.plist` of the engine.
The last two come from the arm64 build. The result has an ad hoc signature.

## Doctor

| Check | Source |
|---|---|
| Flutter | `bin/cache/flutter.version.json` and `bin/internal/engine.version` of the SDK against 3.47.7 and the revision in `RELEASE` |
| Rust | `cargo --version` on `PATH` or in `~/.cargo/bin`, `rustup target list --installed` and a `RUSTUP_HOME` outside `~/.rustup`. Build hooks do not receive that variable |
| Xcode and Metal | `xcodebuild -version` and `xcrun -sdk macosx -f metal` |
| Linux packages | `clang++`, `ninja`, `pkg-config`, `xz` and `pkg-config --exists` of `gtk+-3.0`, `alsa` and `liblzma` |
| Visual Studio | `vswhere` with the component of the C++ tools for x64 |
| CMake, git | their `--version` |
| Engine | the search of the engine locator, the parts of the out folder and the engine revision of a fetched engine against the SDK |
| Download | `gh --version`, `gh auth status` or `GH_TOKEN` and the release repository, when the engine is missing |
| App | the package config and the stamps of the cook |

## Engine actions

`prismarine engine <action>` fetches the engine or builds and packs it. The owner names and publishes the releases
with the tools of the private repository.

| Action | Work |
|---|---|
| `fetch` | Downloads the archive of the target with `gh release download`, checks its SHA-256 in Dart, unpacks it with `tar -xJf` and links its `dart-sdk` |
| `toolchain` | Windows: installs Git, Python, the Build Tools of Visual Studio 2022 and the Debugging Tools and turns on long paths |
| `setup` | Clones depot_tools and Flutter at the engine revision on the branch `prismarine-engine`, a shared clone of the SDK when it is a git checkout, writes `.gclient` without Android, the JDK, esbuild and Fuchsia and runs `gclient sync` |
| `patch` | Applies the patch files with `git am` whose commit subjects are not in `<revision>..HEAD`. The subjects are decoded from their RFC 2047 form. Then compares the tree of the Dart SDK with HEAD plus each prefix of the Dart patches and applies the rest |
| `build` | gn and ninja of the targets that the Flutter tool reads for `--mode`, `release` by default, and the link `flutter_patched_sdk_product` |
| `test` | Linux: the unit tests of Flutter GPU on SwiftShader |
| `package` | Packs an out folder without build files, object files, dot files and debug symbols, with `prismarine-engine.txt`, as `tar` and `xz -9` |

## Platforms

The command runs on macOS, Linux and Windows. `build --universal` works only on macOS, `engine toolchain` only on
Windows and `engine test` only on Linux.

## Checks

Run `dart test` in `packages/prismarine_cli`. The tests cover the findings of doctor from faked tool outputs, the
release repository, the paths of the built app, the patch subjects and the gn arguments.

An incremental run of `patch`, `build` and `package` on the engine trees of a published release gives archives with
the same paths, bytes and modes as the published ones. This checks a change to the engine actions.
