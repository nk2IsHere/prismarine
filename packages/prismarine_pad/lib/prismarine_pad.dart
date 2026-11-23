/// The host's game pads (desktop): SDL3's gamepad subsystem through a small
/// Rust library (SDL runs on a thread of its own), read once a frame. The
/// app turns a reading into its own pad state.
library;

import 'dart:convert';
import 'dart:ffi';

import 'src/native.dart';

/// A pad's buttons in [PadReading.buttons]' bit order.
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

/// One reading of the pad in use: the standard (Xbox) layout, sticks −1…1
/// with y up, triggers 0…1.
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

  /// No pad connected (or no pad support on this machine).
  static const none = PadReading(connected: false);

  final bool connected;

  /// A Microsoft (Xbox) pad, by its USB vendor.
  final bool xbox;
  final int buttons;
  final (double, double) leftStick, rightStick;
  final double leftTrigger, rightTrigger;
  final String name;

  bool pressed(PadButton b) => (buttons >> b.index) & 1 != 0;
}

/// The pad in use, which [HostPads.readInto] fills in place each frame. The
/// sticks go from -1 to 1 with y up and the triggers from 0 to 1.
class PadState {
  bool connected = false;
  int buttons = 0;
  double leftX = 0, leftY = 0, rightX = 0, rightY = 0;
  double leftTrigger = 0, rightTrigger = 0;

  bool pressed(PadButton b) => (buttons >> b.index) & 1 != 0;

  void _clear() {
    connected = false;
    buttons = 0;
    leftX = leftY = rightX = rightY = leftTrigger = rightTrigger = 0;
  }
}

/// A connected pad as the device list names it: its SDL GUID ([uuid], 32
/// hex digits; the same for two pads of one model), which of the pads with
/// that GUID it is ([nth], in connection order), and its name.
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

  /// SDL could not start: pads are never read.
  bool get unavailable => _unavailable;

  /// The pad to play with: null for any (the last one used, else the
  /// first), else only that one (none while it isn't connected).
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

  /// The pad in use now (see [chosen]).
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
      // The library failed to load: no pads.
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

  PadDevice? _halvesOf;
  int _hi = 0, _lo = 0;

  // alloc-cold: once each time the chosen pad changes.
  void _halves(PadDevice c) {
    final (hi, lo) = uuidHalves(c.uuid);
    _hi = hi;
    _lo = lo;
    _halvesOf = c;
  }

  /// Reads the pad in use into [s] without a name or a new reading. With
  /// no pad, [s] reads as not connected.
  void readInto(PadState s) {
    if (_unavailable) {
      s._clear();
      return;
    }
    final NativePadReading r;
    try {
      final c = chosen;
      if (c == null) {
        r = padRead();
      } else {
        if (!identical(c, _halvesOf)) _halves(c);
        r = padReadChosen(_hi, _lo, c.nth);
      }
    } on Object {
      s._clear();
      _unavailable = true;
      return;
    }
    if (r.unavailable != 0 || r.connected == 0) {
      s._clear();
      if (r.unavailable != 0) _unavailable = true;
      return;
    }
    s
      ..connected = true
      ..buttons = r.buttons
      ..leftX = r.leftX
      ..leftY = r.leftY
      ..rightX = r.rightX
      ..rightY = r.rightY
      ..leftTrigger = r.leftTrigger
      ..rightTrigger = r.rightTrigger;
  }
}

/// A GUID's 32 hex digits as two 64-bit halves (big-endian; a bad string
/// reads as zeros).
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
