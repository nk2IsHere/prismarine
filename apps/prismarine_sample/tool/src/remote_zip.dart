import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A file in a zip archive: its name, compression method, sizes, CRC-32 and
/// the offset of its local header.
class ZipEntry {
  ZipEntry(
    this.name,
    this.method,
    this.compressed,
    this.size,
    this.crc,
    this.offset,
  );
  final String name;
  final int method, compressed, size, crc, offset;
}

/// A zip archive behind a download link that redirects to a signed URL. The
/// signed URL expires after some minutes, so each request asks the link for
/// a fresh one. Reads use HTTP range requests.
class RemoteZip {
  RemoteZip(this.link);
  final String link;
  final _http = HttpClient()..userAgent = 'prismarine-sample-fetch';

  void close() => _http.close(force: true);

  Future<Uri> _signed() async {
    final req = await _http.getUrl(Uri.parse(link));
    req.followRedirects = false;
    final res = await req.close();
    await res.drain<void>();
    final to = res.headers.value(HttpHeaders.locationHeader);
    if (res.statusCode ~/ 100 != 3 || to == null) {
      throw HttpException('$link replied ${res.statusCode} with no redirect');
    }
    return Uri.parse(link).resolve(to);
  }

  Future<HttpClientResponse> _range(int start, int end) async {
    final req = await _http.getUrl(await _signed());
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final res = await req.close();
    if (res.statusCode != 206) {
      await res.drain<void>();
      throw HttpException('range $start-$end replied ${res.statusCode}');
    }
    return res;
  }

  Future<Uint8List> _bytes(int start, int end) async {
    final b = BytesBuilder(copy: false);
    await (await _range(start, end)).forEach(b.add);
    return b.takeBytes();
  }

  Future<int> _size() async {
    final req = await _http.headUrl(await _signed());
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode != 200) {
      throw HttpException('$link replied ${res.statusCode} to HEAD');
    }
    return res.contentLength;
  }

  /// Reads the central directory of the archive.
  Future<List<ZipEntry>> entries() async {
    final size = await _size();
    final tailStart = size > 70000 ? size - 70000 : 0;
    final tail = await _bytes(tailStart, size - 1);
    final td = ByteData.sublistView(tail);
    var e = tail.length - 22;
    while (e >= 0 && td.getUint32(e, Endian.little) != 0x06054b50) {
      e--;
    }
    if (e < 0) throw const FormatException('no end of central directory');
    var count = td.getUint16(e + 10, Endian.little);
    var cdSize = td.getUint32(e + 12, Endian.little);
    var cdAt = td.getUint32(e + 16, Endian.little);
    if (cdAt == 0xffffffff || count == 0xffff) {
      // The zip64 locator is just before the end record.
      final eocd64 = td.getUint64(e - 20 + 8, Endian.little);
      final z = ByteData.sublistView(await _bytes(eocd64, eocd64 + 55));
      count = z.getUint64(32, Endian.little);
      cdSize = z.getUint64(40, Endian.little);
      cdAt = z.getUint64(48, Endian.little);
    }
    final cd = ByteData.sublistView(await _bytes(cdAt, cdAt + cdSize - 1));
    final out = <ZipEntry>[];
    var p = 0;
    for (var i = 0; i < count; i++) {
      if (cd.getUint32(p, Endian.little) != 0x02014b50) {
        throw const FormatException('bad central directory');
      }
      final method = cd.getUint16(p + 10, Endian.little);
      final crc = cd.getUint32(p + 16, Endian.little);
      var compressed = cd.getUint32(p + 20, Endian.little);
      var size = cd.getUint32(p + 24, Endian.little);
      final nameLen = cd.getUint16(p + 28, Endian.little);
      final extraLen = cd.getUint16(p + 30, Endian.little);
      final commentLen = cd.getUint16(p + 32, Endian.little);
      var offset = cd.getUint32(p + 42, Endian.little);
      final name = String.fromCharCodes(
        Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
      );
      var x = p + 46 + nameLen;
      final xEnd = x + extraLen;
      while (x + 4 <= xEnd) {
        final id = cd.getUint16(x, Endian.little);
        final len = cd.getUint16(x + 2, Endian.little);
        if (id == 1) {
          var k = x + 4;
          if (size == 0xffffffff) {
            size = cd.getUint64(k, Endian.little);
            k += 8;
          }
          if (compressed == 0xffffffff) {
            compressed = cd.getUint64(k, Endian.little);
            k += 8;
          }
          if (offset == 0xffffffff) offset = cd.getUint64(k, Endian.little);
        }
        x += 4 + len;
      }
      out.add(ZipEntry(name, method, compressed, size, crc, offset));
      p = xEnd + commentLen;
    }
    return out;
  }

  /// Downloads [e] into [path], through a `.part` file. Fails when the CRC
  /// or the size does not match the directory.
  Future<void> download(ZipEntry e, String path) async {
    final head = ByteData.sublistView(await _bytes(e.offset, e.offset + 29));
    if (head.getUint32(0, Endian.little) != 0x04034b50) {
      throw FormatException('${e.name}: no local header');
    }
    final start =
        e.offset +
        30 +
        head.getUint16(26, Endian.little) +
        head.getUint16(28, Endian.little);
    final part = File('$path.part')..parent.createSync(recursive: true);
    final sink = part.openWrite();
    final crc = Crc32();
    var size = 0;
    final res = await _range(start, start + e.compressed - 1);
    final Stream<List<int>> data = switch (e.method) {
      0 => res,
      8 => res.transform(ZLibDecoder(raw: true)),
      _ => throw UnsupportedError('${e.name}: zip method ${e.method}'),
    };
    await for (final chunk in data) {
      crc.add(chunk);
      size += chunk.length;
      sink.add(chunk);
    }
    await sink.close();
    if (size != e.size || crc.value != e.crc) {
      part.deleteSync();
      throw FormatException('${e.name}: size or CRC does not match');
    }
    part.renameSync(path);
  }
}

/// The CRC-32 of zip files.
class Crc32 {
  static final _table = Uint32List.fromList([
    for (var n = 0; n < 256; n++) _entry(n),
  ]);

  static int _entry(int n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  }

  int _c = 0xffffffff;

  void add(List<int> bytes) {
    var c = _c;
    for (var i = 0; i < bytes.length; i++) {
      c = _table[(c ^ bytes[i]) & 0xff] ^ (c >> 8);
    }
    _c = c;
  }

  int get value => _c ^ 0xffffffff;
}
