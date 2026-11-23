import 'dart:convert';
import 'dart:typed_data';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:test/test.dart';

void main() {
  GltfBuilder triangle({List<int> idx = const [0, 1, 2]}) {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(
      Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
      'VEC3',
      minMax: true,
    );
    final ind = b.addIndexAccessor(Uint16List.fromList(idx));
    final mesh = b.addMesh('tri', [
      {
        'attributes': {'POSITION': pos},
        'indices': ind,
      },
    ]);
    b.setScene([
      b.addNode({'mesh': mesh}),
    ]);
    return b;
  }

  test(
    'GLB: header, JSON chunk (space-padded), BIN chunk (zero-padded), 4-byte alignment',
    () {
      final glb = triangle().toGlb();
      final bd = ByteData.sublistView(glb);
      expect(bd.getUint32(0, Endian.little), 0x46546C67); // 'glTF'
      expect(bd.getUint32(4, Endian.little), 2);
      expect(bd.getUint32(8, Endian.little), glb.length);
      expect(bd.getUint32(16, Endian.little), 0x4E4F534A); // 'JSON'
      final jsonLen = bd.getUint32(12, Endian.little);
      expect(jsonLen % 4, 0);
      expect(
        bd.getUint32(20 + jsonLen + 4, Endian.little),
        0x004E4942,
      ); // 'BIN\0'
      final parsed = readGlb(glb);
      expect((parsed.json['asset'] as Map)['version'], '2.0');
      expect(validateGltf(parsed.json, parsed.bin), isEmpty);
    },
  );

  test('asset.generator is the given one and a continued GLB keeps it', () {
    String generator(Uint8List glb) =>
        (readGlb(glb).json['asset']! as Map)['generator']! as String;
    expect(generator(triangle().toGlb()), 'prismarine_assets');
    final own = GltfBuilder(generator: 'tool')..addMesh('m', const []);
    final glb = own.toGlb();
    expect(generator(glb), 'tool');
    expect(generator(GltfBuilder.fromGlb(glb).toGlb()), 'tool');
  });

  test('POSITION accessor carries min/max', () {
    final acc = (triangle().json['accessors'] as List).first as Map;
    expect(acc['min'], [0, 0, 0]);
    expect(acc['max'], [1, 1, 0]);
  });

  test('validator flags out-of-range index', () {
    final b = triangle(idx: [0, 1, 7]);
    final p = readGlb(b.toGlb());
    expect(validateGltf(p.json, p.bin), [contains('index 7')]);
  });

  test('validator flags accessor past its buffer view', () {
    final b = triangle();
    final json = jsonDecode(jsonEncode(b.json)) as Map<String, Object?>;
    ((json['accessors'] as List).first as Map)['count'] = 99;
    expect(
      validateGltf(json, readGlb(b.toGlb()).bin),
      contains(contains('exceeds bufferView')),
    );
  });

  test('mat4: compose then invert gives identity', () {
    final m = mat4Compose(
      [1, 2, 3],
      [0, 0.7071067811865476, 0, 0.7071067811865476],
    );
    final i = mat4Mul(m, mat4InvertAffine(m));
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        expect(i[c * 4 + r], closeTo(r == c ? 1 : 0, 1e-9));
      }
    }
  });

  test('validator flags empty arrays (glTF forbids empty entities)', () {
    final b = triangle();
    final json = jsonDecode(jsonEncode(b.json)) as Map<String, Object?>;
    ((json['nodes'] as List).first as Map)['children'] = <int>[];
    expect(
      validateGltf(json, readGlb(b.toGlb()).bin),
      contains(contains('empty')),
    );
  });

  test('validator flags a gap in TEXCOORD_n numbering', () {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(Float32List(9), 'VEC3', minMax: true);
    final uv = b.addFloatAccessor(Float32List(6), 'VEC2');
    b.setScene([
      b.addNode({
        'mesh': b.addMesh('m', [
          {
            'attributes': {'POSITION': pos, 'TEXCOORD_1': uv},
          },
        ]),
      }),
    ]);
    final p = readGlb(b.toGlb());
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('TEXCOORD_1 without TEXCOORD_0')),
    );
  });

  test('validator flags an out-of-range joint on the last vertex', () {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(Float32List(12), 'VEC3', minMax: true);
    final joints = b.addUShort4Accessor(
      Uint16List.fromList([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0]),
    );
    final weights = b.addFloatAccessor(
      Float32List.fromList([
        for (var v = 0; v < 4; v++) ...[1.0, 0, 0, 0],
      ]),
      'VEC4',
    );
    final root = b.addNode({'name': 'root'});
    final skin = b.addSkin({
      'joints': [root],
    });
    b.setScene([
      b.addNode({
        'mesh': b.addMesh('m', [
          {
            'attributes': {
              'POSITION': pos,
              'JOINTS_0': joints,
              'WEIGHTS_0': weights,
            },
          },
        ]),
        'skin': skin,
      }),
      root,
    ]);
    final p = readGlb(b.toGlb());
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('joint 9 >= skin joints 1')),
    );
  });

  test('validator flags zero TANGENT xyz and w other than ±1', () {
    for (final (tan, want) in [
      ([1.0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1], 'TANGENT 1 xyz not unit length'),
      ([1.0, 0, 0, 1, 1, 0, 0, 0.5, 1, 0, 0, 1], 'TANGENT 1 w is not ±1'),
    ]) {
      final b = GltfBuilder();
      final pos = b.addFloatAccessor(Float32List(9), 'VEC3', minMax: true);
      final t = b.addFloatAccessor(
        Float32List.fromList([for (final c in tan) c.toDouble()]),
        'VEC4',
      );
      b.setScene([
        b.addNode({
          'mesh': b.addMesh('m', [
            {
              'attributes': {'POSITION': pos, 'TANGENT': t},
            },
          ]),
        }),
      ]);
      final p = readGlb(b.toGlb());
      expect(validateGltf(p.json, p.bin), contains(contains(want)));
    }
  });

  test('validator flags zero-count accessors and zero-length buffer views', () {
    final p = readGlb(triangle(idx: const []).toGlb());
    final problems = validateGltf(p.json, p.bin);
    expect(problems, contains(contains('accessor 1 has count 0')));
    expect(problems, contains(contains('bufferView 1 has byteLength 0')));
  });

  test('validator flags non-unit NORMAL vectors', () {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(Float32List(9), 'VEC3', minMax: true);
    final nrm = b.addFloatAccessor(
      Float32List.fromList([0, 0, 1, 0, 0, 0, 0, 0, 1]),
      'VEC3',
    );
    b.setScene([
      b.addNode({
        'mesh': b.addMesh('m', [
          {
            'attributes': {'POSITION': pos, 'NORMAL': nrm},
          },
        ]),
      }),
    ]);
    final p = readGlb(b.toGlb());
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('NORMAL 1 not unit length')),
    );
  });

  ({Map<String, Object?> json, Uint8List bin}) clip({
    List<double> times = const [0, 1],
    bool minMax = true,
    List<double> rotations = const [0, 0, 0, 1, 0, 0, 0, 1],
  }) {
    final b = GltfBuilder();
    final node = b.addNode({'name': 'j'});
    final input = b.addFloatAccessor(
      Float32List.fromList(times),
      'SCALAR',
      minMax: minMax,
      target: null,
    );
    final output = b.addFloatAccessor(
      Float32List.fromList(rotations),
      'VEC4',
      target: null,
    );
    b.addAnimation({
      'name': 'a',
      'channels': [
        {
          'sampler': 0,
          'target': {'node': node, 'path': 'rotation'},
        },
      ],
      'samplers': [
        {'input': input, 'output': output, 'interpolation': 'LINEAR'},
      ],
    });
    b.setScene([node]);
    return readGlb(b.toGlb());
  }

  test('validator flags non-increasing animation input', () {
    final p = clip(
      times: [0, 1, 1],
      rotations: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
    );
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('not strictly increasing')),
    );
  });

  test('validator flags animation input without min/max', () {
    final p = clip(minMax: false);
    expect(validateGltf(p.json, p.bin), contains(contains('lacks min/max')));
  });

  test('validator flags non-unit rotation output', () {
    final p = clip(rotations: [0, 0, 0, 1, 0, 0, 0, 0.5]);
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('rotation key 1 not unit length')),
    );
  });

  test('validator flags a skinned mesh node that is not a root', () {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(Float32List(9), 'VEC3', minMax: true);
    final joint = b.addNode({'name': 'j'});
    final skin = b.addSkin({
      'joints': [joint],
    });
    final mesh = b.addMesh('m', [
      {
        'attributes': {'POSITION': pos},
      },
    ]);
    final meshNode = b.addNode({'mesh': mesh, 'skin': skin});
    final parent = b.addNode({
      'children': [meshNode, joint],
    });
    b.setScene([parent]);
    final p = readGlb(b.toGlb());
    expect(
      validateGltf(p.json, p.bin),
      contains(contains('skinned mesh node $meshNode is not a root')),
    );
  });

  test('a sparse accessor replaces the elements at its indices', () {
    final bytes = ByteData(28)
      ..setFloat32(0, 1, Endian.little)
      ..setFloat32(4, 2, Endian.little)
      ..setFloat32(8, 3, Endian.little)
      ..setUint16(12, 2, Endian.little)
      ..setFloat32(16, 9, Endian.little)
      ..setUint32(20, 7, Endian.little);
    final buffer = bytes.buffer.asUint8List();
    final doc = GltfDocument(
      {
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12},
          {'buffer': 0, 'byteOffset': 12, 'byteLength': 2},
          {'buffer': 0, 'byteOffset': 16, 'byteLength': 12},
        ],
        'accessors': [
          {
            'bufferView': 0,
            'componentType': 5126,
            'count': 3,
            'type': 'SCALAR',
            'sparse': {
              'count': 1,
              'indices': {'bufferView': 1, 'componentType': 5123},
              'values': {'bufferView': 2},
            },
          },
          {
            'componentType': 5125,
            'count': 3,
            'type': 'SCALAR',
            'sparse': {
              'count': 1,
              'indices': {
                'bufferView': 1,
                'componentType': 5123,
                'byteOffset': 0,
              },
              'values': {'bufferView': 2, 'byteOffset': 4},
            },
          },
        ],
      },
      [buffer],
    );
    expect(doc.floats(0), [1, 2, 9]);
    expect(doc.uints(1), [0, 0, 7]);
  });
}
