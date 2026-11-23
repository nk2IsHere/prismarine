import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:test/test.dart';

void main() {
  test('reads the host (no pad on a build machine reads as none)', () {
    final pads = HostPads();
    final r = pads.read();
    // The real library loads and SDL starts with these hints. A fake would
    // hide a library that does not start.
    expect(pads.unavailable, isFalse, reason: 'the pad library or SDL failed');
    if (!r.connected) {
      expect(r.buttons, 0);
      expect(r.leftStick, (0.0, 0.0));
    } else {
      // With a pad plugged in, its reading is in range.
      expect(r.leftStick.$1.abs(), lessThanOrEqualTo(1));
      expect(r.leftTrigger, inInclusiveRange(0, 1));
    }
    // Reading again is cheap and stable.
    pads.read();
  });

  test('the device list and a chosen pad that is not there', () {
    final pads = HostPads();
    for (final d in pads.devices()) {
      expect(d.uuid.length, 32);
      expect(d.name, isNotEmpty);
    }
    pads.chosen = const PadDevice(
      uuid: '0123456789abcdeffedcba9876543210',
      nth: 5,
      name: 'Nobody\'s pad',
    );
    expect(pads.read().connected, isFalse);
  });

  test('GUID halves are big-endian', () {
    expect(uuidHalves('0123456789abcdeffedcba9876543210'), (
      0x0123456789abcdef,
      0xfedcba9876543210,
    ));
  });

  test('buttons decode by bit', () {
    const r = PadReading(connected: true, buttons: 1 << 0 | 1 << 13);
    expect(r.pressed(PadButton.a), isTrue);
    expect(r.pressed(PadButton.dpadRight), isTrue);
    expect(r.pressed(PadButton.b), isFalse);
  });

  test('a pad state decodes buttons by bit', () {
    final s = PadState()..buttons = 1 << 2;
    expect(s.pressed(PadButton.x), isTrue);
    expect(s.pressed(PadButton.a), isFalse);
  });
}
