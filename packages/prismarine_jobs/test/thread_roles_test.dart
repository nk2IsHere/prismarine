import 'dart:io' show Platform;

import 'package:prismarine_jobs/prismarine_jobs.dart';
import 'package:test/test.dart';

/// A thread as the system keeps it, recording each call that changes it.
class _Thread implements ThreadCalls {
  _Thread(this.lvl, {this.pol = linuxSchedOther, this.slices = true});

  int lvl, pol;
  bool? eco;
  int io = 0, slc = 0;

  /// True when the kernel keeps a requested slice, from 6.12 on.
  final bool slices;
  final calls = <String>[];

  @override
  int level() => lvl;
  @override
  void setLevel(int level) {
    calls.add('level $level');
    lvl = level;
  }

  @override
  void setEcoQos(bool? on) {
    calls.add('eco $on');
    eco = on;
  }

  @override
  int policy() => pol;
  @override
  void setPolicy(int policy) {
    calls.add('policy $policy');
    pol = policy;
    // sched_setscheduler drops a requested slice.
    slc = 0;
  }

  @override
  int ioPriority() => io;
  @override
  void setIoPriority(int ioprio) {
    calls.add('io ${ioprio.toRadixString(16)}');
    io = ioprio;
  }

  @override
  int slice() => slc;
  @override
  bool setFrameAttr(int nice, int sliceNs) {
    calls.add('attr $nice $sliceNs');
    lvl = nice;
    pol = linuxSchedOther;
    if (slices) slc = sliceNs;
    return true;
  }
}

void main() {
  group('macOS', () {
    test('raise sets user-interactive once', () {
      final t = _Thread(macDefault);
      final r = ThreadRoles(ThreadOs.macos, t)..raise();
      r.raise();
      expect(t.calls, ['level $macUserInteractive']);
      expect(r.inFrameRole(), isTrue);
    });

    test('lower to utility and back; unspecified comes back as default', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.macos, t);
      final prev = r.lower();
      expect(t.lvl, macUtility);
      expect(r.lower(), isNull, reason: 'already utility');
      r.restore(prev);
      expect(t.lvl, macDefault);
    });

    test('a niced process keeps its threads where they are', () {
      final t = _Thread(macDefault);
      final r = ThreadRoles(ThreadOs.macos, t, niced: true);
      expect(r.lower(), isNull);
      expect(t.calls, isEmpty);
    });
  });

  group('Windows', () {
    test('raise: above normal, out of EcoQoS, once', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.windows, t)..raise();
      r.raise();
      expect(t.calls, ['level $winAboveNormal', 'eco false']);
      expect(r.inFrameRole(), isTrue);
    });

    test('lower: below normal in EcoQoS; restore to the system', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.windows, t);
      final prev = r.lower();
      expect((t.lvl, t.eco), (winBelowNormal, true));
      expect(r.inFrameRole(), isFalse);
      r.restore(prev);
      expect((t.lvl, t.eco), (0, null));
    });

    test('a frame thread lowered and restored is opted out again', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.windows, t)..raise();
      r.restore(r.lower());
      expect((t.lvl, t.eco), (winAboveNormal, false));
    });

    test('already low, or an error reading, changes nothing', () {
      for (final level in [winBelowNormal, -2, 0x7fffffff]) {
        final t = _Thread(level);
        expect(ThreadRoles(ThreadOs.windows, t).lower(), isNull);
        expect(t.calls, isEmpty);
      }
    });
  });

  group('Linux', () {
    test('frame on 6.12: a short slice and high best-effort I/O, once', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.linux, t)..raise();
      r.raise();
      expect(t.calls, ['attr 0 $linuxFrameSliceNs', 'io 4000']);
      expect(r.inFrameRole(), isTrue);
    });

    test('frame before 6.12: the slice is tried once, then nice and I/O', () {
      final t = _Thread(0, slices: false);
      final r = ThreadRoles(ThreadOs.linux, t, rlimitNice: 25)..raise();
      t.lvl = 0; // the nice that a refused attr call leaves
      t.calls.clear();
      r.raise();
      r.raise();
      expect(t.calls, ['level -5']);
      expect((t.lvl, t.io), (-5, linuxIoFrame));
    });

    test('frame with RLIMIT_NICE: the nice rides on the slice call', () {
      final t = _Thread(0);
      ThreadRoles(ThreadOs.linux, t, rlimitNice: 25).raise();
      expect(t.calls.first, 'attr -5 $linuxFrameSliceNs');
    });

    test('without RLIMIT_NICE: background by SCHED_BATCH and low I/O', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.linux, t)..raise();
      t.calls.clear();
      final prev = r.lower();
      expect((t.lvl, t.pol, t.io), (0, linuxSchedBatch, linuxIoBackground));
      expect(r.inFrameRole(), isFalse);
      expect(r.lower(), isNull, reason: 'already batch and low');
      r.restore(prev);
      expect((t.lvl, t.pol, t.io), (0, linuxSchedOther, linuxIoFrame));
      // The batch policy dropped the slice. The next frame requests it again.
      t.calls.clear();
      r.raise();
      expect(t.calls, ['attr 0 $linuxFrameSliceNs']);
    });

    test('with RLIMIT_NICE: background at +10 and back', () {
      final t = _Thread(0);
      final r = ThreadRoles(ThreadOs.linux, t, rlimitNice: 25)..raise();
      final prev = r.lower();
      expect((t.lvl, t.io), (10, linuxIoBackground));
      r.restore(prev);
      expect((t.lvl, t.io, t.pol), (-5, linuxIoFrame, linuxSchedOther));
    });

    test('an unreadable I/O priority is left alone', () {
      final t = _Thread(0)..io = -1;
      final r = ThreadRoles(ThreadOs.linux, t, rlimitNice: 20);
      r.restore(r.lower());
      expect(t.calls, ['level 10', 'level 0']);
    });

    test('a thread under another policy keeps it, its I/O still drops', () {
      final t = _Thread(0, pol: 5); // SCHED_IDLE
      final r = ThreadRoles(ThreadOs.linux, t);
      final prev = r.lower();
      expect(t.calls, ['io 4007']);
      r.restore(prev);
      expect((t.pol, t.io), (5, 0));
    });

    test('a limit that only allows the process nice', () {
      final t = _Thread(10, slices: false);
      final r = ThreadRoles(ThreadOs.linux, t, rlimitNice: 20);
      expect(r.frameNice, 0);
      r.raise();
      expect(t.lvl, 0, reason: 'a thread left high comes back');
    });

    test('the step is from the process nice; niced keeps threads', () {
      final r = ThreadRoles(
        ThreadOs.linux,
        _Thread(15),
        processNice: 15,
        niced: true,
        rlimitNice: 40,
      );
      expect((r.frameNice, r.backgroundNice), (10, 19));
      expect(r.lower(), isNull);
    });
  });

  test('elsewhere: nothing', () {
    final t = _Thread(0);
    final r = ThreadRoles(ThreadOs.none, t)..raise();
    r.restore(r.lower());
    expect(t.calls, isEmpty);
    expect(r.inFrameRole(), isNull);
  });

  test('this system: the real calls take and report the roles', () {
    final known = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final prev = lowerThreadQos();
    if (known && !processNiced) {
      expect(prev, isNotNull);
      expect(threadHasFrameRole(), isFalse);
    }
    restoreThreadQos(prev);
    raiseThreadQos();
    // On Linux RLIMIT_NICE decides if a thread can go above the process. At
    // the nice of the process the thread has the role either way.
    expect(threadHasFrameRole(), known ? isTrue : isNull);
  });
}
