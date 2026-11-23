# prismarine_sample

prismarine_sample is the smallest app on the patched engine. It opens a window, clears one 256 by 256 texture through
Flutter GPU and shows it. It checks that a machine can build and start an app on the engine. The gate of prismarine
builds it. It depends on Flutter GPU only, with no package of prismarine and no native code of its own.

## Usage

The app is a Flutter desktop app with runners for macOS, Linux and Windows. Build it in release mode with the flags of
the patched engine, which `fetch.sh` prints after it fetched the engine. A debug build and a release build without the
flags run on the stock engine of Flutter. The [root README](../../README.md#building) has the steps for each platform.

## Example

A release build on an Apple silicon Mac, with the engine fetched into `$PRISMARINE_ENGINE_DIR`:

    cd apps/prismarine_sample
    flutter pub get
    E=$PRISMARINE_ENGINE_DIR/macos-arm64/src
    flutter build macos --release --local-engine-src-path=$E \
      --local-engine=host_release_arm64 --local-engine-host=host_release_arm64
    build/macos/Build/Products/Release/prismarine_sample.app/Contents/MacOS/prismarine_sample

The code of the app is [`lib/main.dart`](lib/main.dart).

## Platforms

The app runs on macOS with Metal and on Linux and Windows with Vulkan. The engine logs its renderer when the app starts,
such as `Using the Impeller rendering backend` on macOS.
