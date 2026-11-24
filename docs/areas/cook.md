# prismarine_cook

`prismarine_cook` cooks a prismarine app. It reads the `prismarine.yaml` of the app, finds the patched engine of its
release, cooks its shaders and runs its asset steps when the hash of their inputs changed. Its `cookHook` cooks the
shaders in the build hook of the app. [prismarine_cli](cli.md) runs the same code before a build. The keys of the
project file are on [the build page](../building.md#your-own-app).

## Stamps

Each output has a stamp with the SHA-256 of its inputs. An output cooks when its stamp is missing or holds another key
and a failed cook leaves no stamp.

| Output | Stamp | Key |
|---|---|---|
| A program tree | `<out>/cook.json` | the cook version, the settings of the entry, the bytes of impellerc, the path, size and time of the Metal compiler and the path and bytes of every file of the tree |
| A manifest | `<out>.cook.json` | the same with the manifest and the folders of its files in place of the tree |
| An asset step | `cook-<id>.json` in its output folder | the command and the path and bytes of every file of its inputs |

A program tree cooks with `buildShaderBundles` of [prismarine_shaders](shaders.md) into `<out>/bundle/<backend>` and
`programRecords` writes `<out>/records.json`. Shards come from the cache in `~/.prismarine/cache/shaders`, which every
checkout on the computer shares. A manifest cooks with one run of impellerc. A stamp is written only when its text
changes, with its time set to the year 2000, since the hook lists it as a dependency and a stamp written during the
build would run the hook again on the next build.

An asset step with `exists` takes an output without a stamp as current when it has every listed file and writes the
stamp. A scene that was prepared before the step had a stamp is then not downloaded again.

## The build hook

Flutter runs the hook of an app before it bundles the assets, in `flutter build`, `flutter run` and `flutter test`. The
hook lists `prismarine.yaml`, impellerc, every source file and folder and each stamp as dependencies. A changed source,
a new engine or a deleted output runs it again.

A hook gets a filtered environment without `PRISMARINE_ENGINE_DIR`. It takes impellerc from
`.dart_tool/prismarine/engine.json` of the app, which the command writes with the engine in use and else from the
fetched engine of the release in `~/.prismarine/engine`.

## The engine locator

The release of an app is the `RELEASE` beside the `flutter_gpu` that its package config resolves, in
`third_party/flutter_engine` of the same prismarine commit, also in a git dependency. The engine folder is
`PRISMARINE_ENGINE_DIR` or `~/.prismarine/engine`. The locator takes the fetched engine `<dir>/<target>` when its
`prismarine-engine.txt` gives the release and else a tree built from the patches in `<dir>/flutter` whose engine
library holds the export `InternalFlutterGpu_PrismarineFeatures`. A search of the bytes of the library finds the
export on every OS.

## Platforms

The package is pure Dart and runs on macOS, Linux and Windows.

## Checks

Run `dart test` in `packages/prismarine_cook`. The tests cover the project file, the stamps, the asset steps, the order
of the engine locator, the search of the export and the choice of impellerc of the hook.
