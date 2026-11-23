# prismarine_pad

prismarine_pad reads the game pads of the host through the gamepad subsystem of SDL3. SDL is built from source into a
small Rust library. Players need no SDL installed. Every pad reads as an Xbox pad, by the position of its buttons. The
details are on [the area page](../../docs/areas/pad.md).

## Usage

`HostPads` starts SDL on its first call. SDL then polls the pads on its own thread. Call `read` once a frame to get a
`PadReading` of the pad in use, with its buttons, its sticks from -1 to 1 with y up and its triggers from 0 to 1.
`pressed` tests a `PadButton`. `devices` lists the connected pads. Setting `chosen` to one of them reads only that pad.
`readInto` fills a `PadState` in place, without the name of the pad, for a frame loop that allocates nothing.
`unavailable` is true when SDL could not start. A machine without pad support then reads `PadReading.none`.

The build hook builds SDL with CMake and a C compiler, which must be installed on every OS.

## Example

The example prints the left stick and the A button of the pad in use once a second. It is
[`example/example.dart`](example/example.dart):

```dart
import 'dart:async';

import 'package:prismarine_pad/prismarine_pad.dart';

/// Reads the pad in use 60 times a second for five seconds and prints the
/// reading once a second.
Future<void> main() async {
  final pads = HostPads();
  print('connected: ${pads.devices()}');
  for (var frame = 0; frame < 300; frame++) {
    final pad = pads.read();
    if (pad.connected && frame % 60 == 0) {
      final (x, y) = pad.leftStick;
      final jump = pad.pressed(PadButton.a);
      print(
        '${pad.name}: move ${x.toStringAsFixed(2)} '
        '${y.toStringAsFixed(2)}, jump $jump',
      );
    }
    await Future<void>.delayed(const Duration(microseconds: 16667));
  }
  if (pads.unavailable) print('no pad support on this machine');
}
```

## Platforms

The package runs on macOS, Linux and Windows. It reads pads that SDL3 supports over USB and Bluetooth.
