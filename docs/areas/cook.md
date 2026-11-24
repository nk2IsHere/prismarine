# prismarine_cook

`prismarine_cook` prepares what an app needs before it is built. It reads the `prismarine.yaml` of the app, finds the
patched engine of its release, compiles its shaders and runs its asset steps when their inputs changed. Its `cookHook`
compiles the shaders in the build hook of the app. [prismarine_cli](cli.md) runs the same code before a build. The
keys of `prismarine.yaml` are on [the build page](../building.md#your-own-app).

## Stamps

Each output has a stamp with the SHA-256 of its inputs. An output is cooked again when its stamp is missing or holds
another key. A failed cook leaves no stamp.

| Output | Stamp | Key |
|---|---|---|
| A program tree | `<out>/cook.json` | the cook version, the settings of the entry, the bytes of impellerc, the path, size and time of the Metal compiler and the path and bytes of every file of the tree |
| A manifest | `<out>.cook.json` | the same with the manifest and the folders of its files in place of the tree |
| An asset step | `cook-<id>.json` in its output folder | the command and the path and bytes of every file of its inputs |

A program tree cooks with `buildShaderBundles` of [prismarine_shaders](shaders.md) into `<out>/bundle/<backend>` and
`programRecords` writes `<out>/records.json`. Shards come from the cache in `~/.prismarine/cache/shaders`, which every
checkout on the computer shares. A manifest cooks with one run of impellerc. A stamp is written only when its text
changes, and its time is set to the year 2000. The hook lists the stamp as a dependency, so a stamp with the time of
the build would run the hook again on the next build.

An asset step with `exists` does not run when its output folder has no stamp but holds every listed file. It writes
the stamp then. A scene that was prepared before the step had a stamp is not downloaded again.

## The build hook

Flutter runs the hook of an app before it bundles the assets, in `flutter build`, `flutter run` and `flutter test`. The
hook lists `prismarine.yaml`, impellerc, every source file and folder and each stamp as dependencies. A changed source,
a new engine or a deleted output runs it again.

Flutter passes a hook a filtered environment without `PRISMARINE_ENGINE_DIR`. The hook takes impellerc from
`.dart_tool/prismarine/engine.json` of the app, where the prismarine command records the engine in use. Without that
file it takes the fetched engine of the release in `~/.prismarine/engine`.

## The engine locator

The release of an app is the `engine` of its `prismarine.yaml`. It must equal the `RELEASE` file in
`third_party/flutter_engine` of the prismarine commit whose `flutter_gpu` the package config of the app resolves, also
in a git dependency: the vendored `flutter_gpu` works only on its own engine. The build hook and the command stop with
the fix when the two differ. `prismarine engine release` rewrites the `engine` of every app in the checkout. The
engine folder is
`PRISMARINE_ENGINE_DIR` or `~/.prismarine/engine`. The locator takes the fetched engine `<dir>/<target>` when its
`prismarine-engine.txt` gives the release. Else it takes a tree built from the patches in `<dir>/flutter` whose engine
library holds the export `InternalFlutterGpu_PrismarineFeatures`. The locator searches the bytes of the library for
the export, which works on every OS.

## Platforms

The package is pure Dart and runs on macOS, Linux and Windows.

## Checks

Run `dart test` in `packages/prismarine_cook`. The tests cover the project file, the stamps, the asset steps, the order
of the engine locator, the search of the export and the choice of impellerc of the hook.
