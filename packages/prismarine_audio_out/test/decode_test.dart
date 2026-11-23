import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:prismarine_audio_out/prismarine_audio_out.dart';
import 'package:test/test.dart';

// Two short files of generated tones and noise, made for the crate's
// checksum test.
final ogg = File('native/tests/data/synthetic.ogg').absolute.path;
final mp3 = File('native/tests/data/synthetic.mp3').absolute.path;

/// Returns every frame of [s], read in reads of [chunk] frames.
Float32List readAll(PcmSource s, {int chunk = 997}) {
  final out = Float32List(s.frames * s.channels);
  final buf = Float32List(chunk * s.channels);
  for (var f = 0; f < s.frames; f += chunk) {
    final n = s.read(buf, f, chunk);
    out.setRange(f * s.channels, (f + n) * s.channels, buf);
  }
  return out;
}

void main() {
  test('both formats decode whole, with the format of the file', () {
    final o = decodeAudioFile(ogg);
    expect((o.channels, o.sampleRate, o.frames), (2, 48000, 72000));
    final m = decodeAudioFile(mp3);
    expect((m.channels, m.sampleRate, m.frames), (2, 44100, 67968));
    expect(o.samples.any((v) => v.abs() > 0.01), isTrue);
  });

  test('a file that is not audio fails with a FormatException', () {
    final f = File('${Directory.systemTemp.path}/prismarine_bad.ogg')
      ..writeAsBytesSync([1, 2, 3, 4]);
    addTearDown(f.deleteSync);
    expect(() => decodeAudioFile(f.path), throwsA(isA<FormatException>()));
    expect(
      () => decodeAudioFile('${f.path}.missing'),
      throwsA(isA<FormatException>()),
    );
  });

  test('the cache and a background decode give the bits of a whole decode', () {
    final whole = decodeAudioFile(mp3);
    expect(PcmCache.want(mp3), inInclusiveRange(-1, 2));
    final cached = CachedPcmSource.acquire(mp3);
    expect(cached.wait(), isTrue);
    expect(cached.ready, isTrue);
    expect(readAll(cached), whole.samples);
    expect(PcmCache.stats().wanted, greaterThan(0));

    final job = AsyncPcmSource.start(
      ogg,
      channels: 2,
      sampleRate: 48000,
      frames: 72000,
    );
    final sw = Stopwatch()..start();
    while (!job.ready && sw.elapsed < const Duration(seconds: 10)) {
      sleep(const Duration(milliseconds: 2));
    }
    expect(job.failed, isFalse);
    expect(readAll(job), decodeAudioFile(ogg).samples);
  });

  test('a stream reads its head as the whole decode does', () async {
    final whole = decodeAudioFile(ogg);
    final s = StreamingPcmSource.open(
      ogg,
      channels: whole.channels,
      sampleRate: whole.sampleRate,
      frames: whole.frames,
    );
    addTearDown(s.close);
    final sw = Stopwatch()..start();
    while (!s.ready && sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(s.failed, isFalse);
    // The head is decoded at open and these frames are there already.
    final n = (StreamingPcmSource.headSeconds * whole.sampleRate).floor();
    final out = Float32List(n * 2);
    expect(s.read(out, 0, n), n);
    expect(out, whole.samples.sublist(0, n * 2));
  });
}
