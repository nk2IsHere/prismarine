import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

void main() {
  group('RingIndex', () {
    test(
      'fills, then overwrites the oldest; slotAt counts back from the newest',
      () {
        final r = RingIndex(3);
        expect(r.length, 0);
        expect([r.push(), r.push()], [0, 1]);
        expect(r.length, 2);
        expect(r.slotAt(0), 1);
        expect(r.slotAt(1), 0);
        expect(() => r.slotAt(2), throwsRangeError);
        expect([r.push(), r.push(), r.push()], [2, 0, 1]);
        expect(r.length, 3);
        // Newest is slot 1, then 0, then 2.
        expect([r.slotAt(0), r.slotAt(1), r.slotAt(2)], [1, 0, 2]);
        r.clear();
        expect(r.length, 0);
        expect(r.push(), 0);
      },
    );
  });

  group('Mark', () {
    test('points are fractions of the frame, clamped; JSON round trip', () {
      expect(Mark.normalize(400, 225, 800, 450), (0.5, 0.5));
      expect(Mark.normalize(-10, 900, 800, 450), (0.0, 1.0));
      final m = Mark(MarkTool.arrow, [(0.1, 0.2), (0.333333, 0.9)]);
      final j = m.toJson();
      expect(j, {
        'tool': 'arrow',
        'points': [
          [0.1, 0.2],
          [0.3333, 0.9],
        ],
      });
      final back = Mark.fromJson(j);
      expect(back.tool, MarkTool.arrow);
      expect(back.points, [(0.1, 0.2), (0.3333, 0.9)]);
      final p = Mark.fromJson(
        Mark(MarkTool.point, [(0.5, 0.5)], label: '2').toJson(),
      );
      expect(p.label, '2');
    });
  });

  group('Issue', () {
    const meta = HistoryMeta(
      frame: 10945,
      time: 182.4,
      wall: 30.5,
      scene: 'adv_theNetherTransition.scene',
    );
    final issue = Issue(
      frames: [
        IssueFrame(
          meta: meta,
          note: 'bow vanishes',
          offset: -0.63,
          marks: [
            Mark(MarkTool.point, [(0.5, 0.5)], label: '1'),
          ],
        ),
      ],
      width: 800,
      height: 450,
      openedAt: 183.03,
    );

    test('issue.json names the frames and their images', () {
      final j = issue.toJson();
      expect(j['note'], 'bow vanishes');
      expect(j['ring'], {'width': 800, 'height': 450});
      final f = (j['frames']! as List).single as Map;
      expect(f['frame'], 10945);
      expect(f['t'], 182.4);
      expect(f['offset'], -0.63);
      expect(f['image'], 'frame_10945.png');
      expect(f['marked'], 'frame_10945.marked.png');
      expect(f['note'], 'bow vanishes');
      expect((f['marks'] as List).single, {
        'tool': 'point',
        'points': [
          [0.5, 0.5],
        ],
        'label': '1',
      });
    });

    test('the issue note joins its frames\' notes, oldest first', () {
      IssueFrame f(int n, String note) => IssueFrame(
        meta: HistoryMeta(frame: n, time: n / 60, wall: n / 60),
        offset: 0,
        marks: const [],
        note: note,
      );
      final i = Issue(
        frames: [f(1, 'arm clips'), f(2, ''), f(3, 'shadow pops')],
        width: 640,
        height: 360,
        openedAt: 1,
      );
      expect(i.note, 'arm clips; shadow pops');
      expect(
        ((i.toJson()['frames']! as List)[1] as Map).containsKey('note'),
        isFalse,
      );
    });

  });

}
