import 'dart:convert';
import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:prismarine_shaders/src/shader_bundle_split.dart';
import 'package:test/test.dart';

/// A bundle of one shader with a backend in every slot, each carrying a
/// uniform struct with a field, a texture, an input and some code.
///
/// [extraField] adds a BackendShader field past the schema's last.
Uint8List _bundle({bool extraField = false}) {
  final b = fb.Builder();
  int backend(int tag) {
    final fname = b.writeString('data');
    b.startTable(8);
    b.addOffset(0, fname);
    b.addUint32(1, 10);
    b.addUint64(4, 16 * tag);
    final field = b.endTable();
    final fields = b.writeList([field]);
    final sname = b.writeString('BufferPost');
    b.startTable(6);
    b.addOffset(0, sname);
    b.addUint64(4, 16 * tag);
    b.addOffset(5, fields);
    final st = b.writeList([b.endTable()]);
    final tname = b.writeString('Sampler_sInput0');
    b.startTable(4);
    b.addOffset(0, tname);
    b.addUint64(3, tag);
    final tex = b.writeList([b.endTable()]);
    final iname = b.writeString('vsi0');
    b.startTable(9);
    b.addOffset(0, iname);
    b.addUint64(1, 0);
    b.addUint32(4, 9);
    final input = b.writeList([b.endTable()]);
    final tbname = b.writeString('sDepthParameters');
    b.startTable(7);
    b.addOffset(0, tbname);
    b.addUint64(4, tag + 4);
    b.addBool(5, false);
    b.addBool(6, true);
    final texel = b.writeList([b.endTable()]);
    final sepname = b.writeString('Sampler_sInput2');
    b.startTable(5);
    b.addOffset(0, sepname);
    b.addUint64(3, tag + 1);
    b.addBool(4, true);
    final sep = b.writeList([b.endTable()]);
    final smpname = b.writeString('s0');
    b.startTable(4);
    b.addOffset(0, smpname);
    b.addUint64(3, tag + 2);
    final smp = b.writeList([b.endTable()]);
    final code = b.writeListUint8([for (var k = 0; k < 8; k++) tag]);
    final entry = b.writeString('main');
    b.startTable(extraField ? 15 : 14);
    b.addUint8(0, 1);
    b.addOffset(1, entry);
    b.addOffset(2, input);
    b.addOffset(3, st);
    b.addOffset(4, tex);
    b.addOffset(5, code);
    b.addOffset(10, texel);
    b.addOffset(11, sep);
    b.addOffset(12, smp);
    b.addUint32(13, 3);
    if (extraField) b.addUint32(14, 1);
    return b.endTable();
  }

  final backends = [for (var t = 1; t <= 5; t++) backend(t)];
  final name = b.writeString('g0123');
  b.startTable(6);
  b.addOffset(0, name);
  for (var t = 0; t < 5; t++) {
    b.addOffset(t + 1, backends[t]);
  }
  final shaders = b.writeList([b.endTable()]);
  b.startTable(2);
  b.addOffset(0, shaders);
  b.addUint32(1, 2);
  b.finish(b.endTable(), 'IPSB');
  return b.buffer;
}

void main() {
  test('keeping every backend changes nothing', () {
    final x = _bundle();
    final all = keepShaderBundleBackends(x, shaderBundleBackends.keys.toSet());
    expect(
      jsonEncode(decodeShaderBundle(all)),
      jsonEncode(decodeShaderBundle(x)),
    );
  });

  test('a split keeps one backend whole and drops the rest', () {
    final x = _bundle();
    final whole = decodeShaderBundle(x) as List;
    final one =
        decodeShaderBundle(keepShaderBundleBackends(x, {'vulkan'})) as List;
    final shader = (one[0] as List)[0] as List;
    final orig = (whole[0] as List)[0] as List;
    expect(shader[0], orig[0]);
    expect([shader[1], shader[2], shader[3], shader[4]], everyElement(isNull));
    expect(jsonEncode(shader[5]), jsonEncode(orig[5]));
    expect(one[1], 2);
    // Texel buffers, separate textures, samplers and the options of Metal.
    final vk = shader[5] as List;
    expect([vk[10], vk[11], vk[12]], everyElement(hasLength(1)));
    expect(vk[13], 3);
  });

  test("a Metal library fills only metal_desktop's compiled field and "
      'round-trips', () {
    final x = _bundle();
    final lib = Uint8List.fromList([0x4d, 0x54, 0x4c, 0x42, 1, 2, 3]);
    final mtl = keepShaderBundleBackends(
      x,
      {'metal_desktop'},
      metalCompiled: {'g0123': lib},
    );
    final shader = ((decodeShaderBundle(mtl) as List)[0] as List)[0] as List;
    final backend = shader[shaderBundleBackends['metal_desktop']!] as List;
    expect(backend[backendShaderCompiled], lib);
    final orig = ((decodeShaderBundle(x) as List)[0] as List)[0] as List;
    final want = [...(orig[2] as List)]..[backendShaderCompiled] = lib;
    expect(jsonEncode(backend), jsonEncode(want));
    // A library stays when the bundle is copied again. A shader without
    // a library gets none.
    expect(
      jsonEncode(
        decodeShaderBundle(keepShaderBundleBackends(mtl, {'metal_desktop'})),
      ),
      jsonEncode(decodeShaderBundle(mtl)),
    );
    final vk = keepShaderBundleBackends(
      x,
      {'vulkan'},
      metalCompiled: {'g0123': lib},
    );
    final vs = ((decodeShaderBundle(vk) as List)[0] as List)[0] as List;
    expect((vs[5] as List)[backendShaderCompiled], isNull);
    final other = keepShaderBundleBackends(
      x,
      {'metal_desktop'},
      metalCompiled: {'other': lib},
    );
    final os = ((decodeShaderBundle(other) as List)[0] as List)[0] as List;
    expect((os[2] as List)[backendShaderCompiled], isNull);
  });

  test("a resource's unused mark survives a split", () {
    final one =
        decodeShaderBundle(keepShaderBundleBackends(_bundle(), {'vulkan'}))
            as List;
    final vk = ((one[0] as List)[0] as List)[5] as List;
    expect(((vk[10] as List)[0] as List)[6], 1);
    expect(((vk[11] as List)[0] as List)[4], 1);
  });

  test('a field the schema lacks is refused, not dropped', () {
    expect(
      () => keepShaderBundleBackends(_bundle(extraField: true), {'vulkan'}),
      throwsFormatException,
    );
  });
}
