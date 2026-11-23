# Toolchain

`tools/toolchain/env.sh` gives every repository on a machine the same Flutter SDK, pub cache and engine directory. Each
one is a folder under `~/.prismarine` by default, which can be a symbolic link to the folder that the machine already
has, such as the Flutter SDK of an older checkout. The script uses the real path of a link. Paths in package configs and
build caches then stay the same as before the link, and a build does not start again from nothing. The
[README](../../tools/toolchain/README.md) lists the variables.

The engine directory holds a fetched engine in `<target>/src`, such as `macos-arm64/src`, and a built one in
`flutter/engine/src`, as the [engine](engine.md) scripts put them. The script picks the out dir of a release engine for
the CPU of the machine, `host_release_arm64` on an Apple silicon Mac and `host_release` on an x86-64 machine. A fetched
engine comes before a built one. The landing gate builds the sample app with `prismarine_engine_args` from the script.

## Platforms

The script runs in bash and zsh on macOS and Linux. Windows has no form of it.

## Checks

Source the script in a shell without the variables and print them:

    env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'source tools/toolchain/env.sh; echo $PRISMARINE_FLUTTER $PUB_CACHE'
