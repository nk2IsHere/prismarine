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
