# Toolchain

`tools/toolchain/env.sh` sets the toolchain of the machine in a bash or zsh shell. Each machine has one Flutter SDK,
one pub cache and one engine directory. Every repository on the machine uses them. Source the script before a build,
a test run or a gate. The details are on [the area page](../../docs/areas/toolchain.md).

## Usage

    source tools/toolchain/env.sh
    cd apps/prismarine_sample
    flutter build macos --release "${prismarine_engine_args[@]}"

| Variable | Effect |
|---|---|
| `PRISMARINE_FLUTTER` | The Flutter SDK, `~/.prismarine/flutter` by default. Its `bin` folder goes first on the `PATH` |
| `PRISMARINE_PUB_CACHE` | The pub cache, `~/.prismarine/pub-cache` by default. The script exports it as `PUB_CACHE` |
| `PRISMARINE_ENGINE_DIR` | The engine directory, `~/.prismarine/engine` by default |

The script also exports `PRISMARINE_IMPELLERC`, the impellerc of the patched engine, and sets the array
`prismarine_engine_args` to the flags of a release `flutter build` on that engine. A fetched engine comes before a
built one. Without a patched engine the array is empty and the build runs on the stock engine. A missing Flutter SDK or
pub cache leaves `PATH` or `PUB_CACHE` as they are, which keeps a Flutter SDK that is already on your `PATH`.

## Example

A machine with its toolchain in other folders links them once:

    mkdir -p ~/.prismarine
    ln -s <your Flutter SDK> ~/.prismarine/flutter
    ln -s <your pub cache> ~/.prismarine/pub-cache
    ln -s <your engine directory> ~/.prismarine/engine

## Platforms

The script runs on macOS and Linux. Windows has no form of it.
