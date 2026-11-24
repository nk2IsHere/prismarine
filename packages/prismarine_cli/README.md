# prismarine_cli

prismarine_cli is the `prismarine` command. It checks your toolchain, fetches the patched engine or builds it from its
patches, cooks the shaders and assets of an app and builds and runs it. [The build page](../../docs/building.md) is
the guide and the details are on [the area page](../../docs/areas/cli.md).

## Usage

Put the `bin` folder of your checkout on your `PATH`. `bin/prismarine` runs on macOS and Linux and
`bin\prismarine.bat` in `cmd` and PowerShell on Windows.

```sh
prismarine doctor
prismarine run
prismarine build linux --app=apps/prismarine_sample
prismarine engine build --cpu=both
```

`prismarine --help` lists the commands and `prismarine <command> --help` the options of each with examples.

## Example

The command is also a library. The example runs the doctor in the current folder. It is
[`example/example.dart`](example/example.dart):

```dart
import 'package:prismarine_cli/prismarine_cli.dart';

/// Runs `prismarine doctor` in the current folder and prints its exit code.
Future<void> main() async {
  print('doctor exited with ${await runPrismarine(['doctor'])}');
}
```

## Platforms

The command runs on macOS, Linux and Windows. `build --universal` is for macOS, `engine toolchain` for Windows and
`engine test` for Linux.
