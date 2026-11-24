# prismarine_jobs

prismarine_jobs runs work off the frame in worker isolates and gives threads a role, the frame role or the background
role, through the scheduler of the OS. `MemoryRoom` checks that the machine has memory to spare for reads far ahead of
their use. The details are on [the area page](../../docs/areas/jobs.md).

## Usage

`JobPool` runs one-shot jobs on worker isolates, at most `workers` of them at a time. `run` takes a function, a
`JobPriority` and an optional `JobToken`. It returns the result of the function, which comes back from the worker
without a copy. Queued jobs start by priority and then in order. A cancelled token fails a job that has not started with
`JobCancelled`. A background job runs in the background role.

`raiseThreadQos` gives the calling thread the frame role, for the work that holds up a frame, such as the tick of a
simulation. `lowerThreadQos` gives it the background role and returns the value for `restoreThreadQos`. None of these
calls needs privileges.

`MemoryRoom.deep` is true when the memory readings of the OS show room for reads far ahead, such as the decode of the
next level. It reads the OS at most once a second. The variables `PRISMARINE_AHEAD_BUDGET_MB`,
`PRISMARINE_AHEAD_FREE_MB` and `PRISMARINE_AHEAD` change its limits. `processFootprint` returns the memory that the
process holds, in bytes.

## Example

The example queues three jobs on a pool with one worker and cancels one of them. It is
[`example/example.dart`](example/example.dart):

```dart
import 'package:prismarine_jobs/prismarine_jobs.dart';

int checksum(List<int> bytes) =>
    bytes.fold(0, (s, b) => (s * 31 + b) & 0xffffffff);

Future<void> main() async {
  final pool = JobPool(workers: 1);
  final data = List<int>.generate(1 << 20, (i) => i & 0xff);

  // The pool starts queued jobs by priority. A token cancels a job that has
  // not started yet.
  final music = pool.run(() => checksum(data), label: 'music');
  final token = JobToken();
  final old = pool.run(() => checksum(data), label: 'old', token: token);
  final level = pool.run(
    () => checksum(data),
    priority: JobPriority.frame,
    label: 'level',
  );
  token.cancel();
  print('music ${await music}, level ${await level}');
  try {
    await old;
  } on JobCancelled catch (e) {
    print('cancelled ${e.label}');
  }

  // A read far ahead of its use pays off only with memory to spare.
  final room = MemoryRoom();
  print('read ahead: ${room.deep}');
  pool.close();
}
```

## Platforms

The package is pure Dart with calls into the OS through `dart:ffi`. The thread roles, the memory readings and
`processFootprint` have their own implementation for macOS, Linux and Windows.
