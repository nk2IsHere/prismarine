import 'package:prismarine_jobs/prismarine_jobs.dart';
import 'package:test/test.dart';

void main() {
  const roomy = MemoryReadings(
    physicalMb: 65536,
    processMb: 4000,
    availableMb: 30000,
  );

  MemoryRoom room() => MemoryRoom(minFreeMb: 2048, budgetMb: null);

  test('room everywhere reads deep', () {
    expect(room().decide(roomy, null), isTrue);
  });

  test('the OS saying memory is short (macOS level, Windows notification)', () {
    const r = MemoryReadings(
      physicalMb: 16384,
      processMb: 1000,
      pressure: true,
    );
    expect(room().decide(r, null), isFalse);
  });

  test('paging since the check before', () {
    const before = MemoryReadings(
      physicalMb: 16384,
      processMb: 1000,
      pagedOutMb: 17000,
    );
    const now = MemoryReadings(
      physicalMb: 16384,
      processMb: 1000,
      pagedOutMb: 17200,
    );
    const still = MemoryReadings(
      physicalMb: 16384,
      processMb: 1000,
      pagedOutMb: 17010,
    );
    expect(room().decide(now, before), isFalse);
    // A swap long in use that does not grow is old pages.
    expect(room().decide(still, before), isTrue);
  });

  test('little available, a full cgroup or commit limit', () {
    const avail = MemoryReadings(
      physicalMb: 65536,
      processMb: 1000,
      availableMb: 1000,
    );
    const cgroup = MemoryReadings(
      physicalMb: 65536,
      processMb: 1400,
      availableMb: 30000,
      cgroupRoomMb: 100,
    );
    const commit = MemoryReadings(
      physicalMb: 8192,
      processMb: 1000,
      availableMb: 3000,
      commitRoomMb: 500,
    );
    for (final r in [avail, cgroup, commit]) {
      expect(room().decide(r, null), isFalse, reason: '$r');
    }
  });

  test(
    'the process past its budget: 40 % of physical memory, or the set one',
    () {
      const big = MemoryReadings(physicalMb: 16384, processMb: 7000);
      expect(room().decide(big, null), isFalse);
      expect(
        MemoryRoom(minFreeMb: 2048, budgetMb: 8000).decide(big, null),
        isTrue,
      );
    },
  );

  test('a reader that throws reads short', () {
    final r = MemoryRoom(read: () => throw StateError('none'));
    expect(r.deep, anyOf(isFalse, isTrue)); // PRISMARINE_AHEAD may force it
    if (!r.why.startsWith('PRISMARINE_AHEAD')) expect(r.deep, isFalse);
  });
}
