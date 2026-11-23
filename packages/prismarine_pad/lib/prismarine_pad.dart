/// The gamepads of a desktop host, read once a frame through the gamepad
/// subsystem of SDL3. The app turns a reading into its own pad state.
library;

import 'dart:convert';
import 'dart:ffi';

import 'src/native.dart';

/// The buttons of a pad in the bit order of [PadReading.buttons].
enum PadButton {
  a,
  b,
  x,
  y,
  leftShoulder,
  rightShoulder,
  back,
  start,
  leftStick,
  rightStick,
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
}

/// One reading of the pad in use in the standard Xbox layout. Sticks range
/// from −1 to 1 with y up. Triggers range from 0 to 1.
class PadReading {
  const PadReading({
    required this.connected,
    this.xbox = false,
    this.buttons = 0,
    this.leftStick = (0, 0),
    this.rightStick = (0, 0),
    this.leftTrigger = 0,
    this.rightTrigger = 0,
    this.name = '',
  });

  /// The reading when no pad is connected or the machine has no pad support.
  static const none = PadReading(connected: false);

  final bool connected;

  /// True for a Microsoft Xbox pad, found by its USB vendor.
  final bool xbox;
  final int buttons;
  final (double, double) leftStick, rightStick;
  final double leftTrigger, rightTrigger;
  final String name;

  bool pressed(PadButton b) => (buttons >> b.index) & 1 != 0;
}

/// A connected pad in the device list. [uuid] is its SDL GUID of 32 hex
/// digits, which is the same for two pads of one model. [nth] is its place
/// among the pads with that GUID in connection order.
class PadDevice {
  const PadDevice({required this.uuid, this.nth = 0, required this.name});
  final String uuid;
  final int nth;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is PadDevice && other.uuid == uuid && other.nth == nth;

  @override
  int get hashCode => Object.hash(uuid, nth);

  @override
  String toString() => '$name ($uuid#$nth)';
}

String _text(Array<Uint8> a, int n) {
  final b = <int>[];
  for (var i = 0; i < n && a[i] != 0; i++) {
    b.add(a[i]);
  }
  return utf8.decode(b, allowMalformed: true);
}

/// The host's pads. The first call starts SDL.
class HostPads {
  bool _unavailable = false;

  /// True when SDL could not start. No pad is read then.
  bool get unavailable => _unavailable;

  /// The pad to play with. Null selects the last pad used, else the first
  /// pad. A device selects only that pad, which reads as none while it is
  /// not connected.
  PadDevice? chosen;

  /// The connected pads, in connection order.
  List<PadDevice> devices() {
    if (_unavailable) return const [];
    final out = <PadDevice>[];
    try {
      for (var i = 0; i < 64; i++) {
        final d = padDevice(i);
        if (d.present == 0) break;
        final hex = StringBuffer();
        for (var k = 0; k < 16; k++) {
          hex.write(d.uuid[k].toRadixString(16).padLeft(2, '0'));
        }
        out.add(PadDevice(uuid: '$hex', nth: d.nth, name: _text(d.name, 64)));
      }
    } on Object {
      _unavailable = true;
      return const [];
    }
    return out;
  }

  /// Reads the pad in use now, as [chosen] selects it.
  PadReading read() {
    if (_unavailable) return PadReading.none;
    final NativePadReading r;
    try {
      final c = chosen;
      if (c == null) {
        r = padRead();
      } else {
        final (hi, lo) = uuidHalves(c.uuid);
        r = padReadChosen(hi, lo, c.nth);
      }
    } on Object {
      // The library failed to load. No pad is read.
      _unavailable = true;
      return PadReading.none;
    }
    if (r.unavailable != 0) {
      _unavailable = true;
      return PadReading.none;
    }
    if (r.connected == 0) return PadReading.none;
    return PadReading(
      connected: true,
      xbox: r.xbox != 0,
      buttons: r.buttons,
      leftStick: (r.leftX, r.leftY),
      rightStick: (r.rightX, r.rightY),
      leftTrigger: r.leftTrigger,
      rightTrigger: r.rightTrigger,
      name: _text(r.name, 64),
    );
  }
}

/// Returns the 32 hex digits of a GUID as two big-endian 64-bit halves. A
/// bad string returns zeros.
(int, int) uuidHalves(String hex) {
  int half(int at) {
    var v = 0;
    for (var i = at; i < at + 16; i++) {
      final d = i < hex.length ? int.tryParse(hex[i], radix: 16) ?? 0 : 0;
      v = (v << 4) | d;
    }
    return v;
  }

  return (half(0), half(16));
}
