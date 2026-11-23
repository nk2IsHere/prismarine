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
