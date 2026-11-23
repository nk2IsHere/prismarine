import 'dart:typed_data';

import 'frame_plan.dart';

Map<String, Object?> _ref(BufferRef r) => {
  'buffer': r.buffer,
  'offset': r.offset,
  'size': ?r.size,
  'format': ?r.format,
};

BufferRef _refFrom(Map r) => BufferRef(
  r['buffer'] as String,
  offset: r['offset'] as int? ?? 0,
  size: r['size'] as int?,
  format: r['format'] as String?,
);

/// The format tag of the form of [planToJson] unless a caller gives its own.
const framePlanFormat = 'prismarine.frame/1';

/// Writes [p] as JSON with the tag [format]. Byte payloads, such as constant
/// buffers, texel buffers and constant texels, are kept apart as blobs by
/// name. [putBlob] stores a byte payload and returns its blob name.
/// [planFromJson] reads the JSON back.
Map<String, Object?> planToJson(
  FramePlan p,
  String Function(Uint8List bytes) putBlob, {
  String format = framePlanFormat,
}) {
  Map<String, Object?> res(StageResources r) => {
    'blocks': {
      // The bytes of a frame role for this frame (FrameRole).
      for (final MapEntry(:key, :value) in r.blocks.entries)
        key: putBlob(p.block(value)),
    },
    'textures': {
      for (final MapEntry(:key, :value) in r.textures.entries)
        key: switch (value) {
          FileTexture(:final stem, :final srgb) => {
            'file': stem,
            if (srgb) 'srgb': true,
          },
          final TargetTexture t => {
            'target': t.target,
            'mip': t.mip,
            'mips': t.mips,
            'layer': t.layer,
            'layers': t.layers,
            if (t.srgb) 'srgb': true,
          },
          BufferTexture(:final bytes, :final format) => {
            'buffer': putBlob(p.block(bytes)),
            'format': format,
          },
          ConstantTexture(
            :final format,
            :final texel,
            :final type,
            :final width,
            :final height,
          ) =>
            {
              'constant': putBlob(texel),
              'format': format,
              'type': type,
              'width': ?width,
              'height': ?height,
            },
          BufferTextureRef(:final ref) => {'ref': _ref(ref)},
        },
    },
    'storage': {
      for (final MapEntry(:key, :value) in r.storage.entries)
        key: switch (value) {
          InlineBuffer(:final bytes, :final format) => {
            'inline': putBlob(p.block(bytes)),
            'format': ?format,
          },
          ImageRef(:final target, :final mip, :final layer) => {
            'image': target,
            'mip': mip,
            'layer': layer,
          },
          final BufferRef r => {'ref': _ref(r)},
        },
    },
    'samplers': {
      for (final MapEntry(:key, :value) in r.samplers.entries)
        '$key': {
          'min': value.minLinear,
          'mag': value.magLinear,
          'mip': value.mipLinear,
          'address': value.address,
          'anisotropy': value.anisotropy,
          'compare': value.compare,
          'lod': [value.minLod, value.maxLod, value.lodBias],
          'border': value.border,
        },
    },
  };
  Map<String, Object?> att(Attachment a) => {
    'target': a.target,
    'mip': a.mip,
    'layer': a.layer,
    'clear': a.clear,
    'clearDepth': a.clearDepth,
    'clearStencil': a.clearStencil,
    if (a.srgb) 'srgb': true,
  };
  return {
    'format': format,
    'buffers': {
      for (final MapEntry(:key, :value) in p.buffers.entries)
        key: {
          'size': value.size,
          if (value.initial case final i?) 'initial': putBlob(i),
          if (value.readBack) 'readBack': true,
        },
    },
    'targets': {
      for (final MapEntry(:key, :value) in p.targets.entries)
        key: {
          'width': value.width,
          'height': value.height,
          'format': value.format,
          'layers': value.layers,
          'mips': value.mips,
          'samples': value.samples,
          if (value.storage) 'storage': true,
          if (value.volume) 'volume': true,
          if (value.initial case final i?) 'initial': putBlob(p.block(i)),
        },
    },
    'passes': [
      for (final pass in p.passes)
        switch (pass) {
          final RenderPassPlan r => {
            'render': r.name,
            'colors': [for (final c in r.colors) att(c)],
            'depth': r.depth == null ? null : att(r.depth!),
            // The rows of a pass are its first draws (RenderPassPlan.allDraws).
            'draws': [
              for (final d in r.allDraws)
                {
                  'label': d.label,
                  'vertex': d.vertex,
                  'pixel': d.pixel,
                  'geometry': switch (d.geometry) {
                    final DrawMeshGeometry g => {
                      'mesh': g.mesh,
                      'ibuffer': g.ibuffer,
                      'first': g.firstIndex,
                      'count': g.indexCount,
                      'instances': g.instances,
                      if (g.indirect case final r?) 'indirect': _ref(r),
                      if (g.streams.isNotEmpty)
                        'streams': {
                          for (final MapEntry(:key, :value)
                              in g.streams.entries)
                            '$key': [_ref(value.$1), value.$2, value.$3],
                        },
                    },
                    final InlineGeometry g => {
                      'inline': putBlob(g.bytes),
                      'stride': g.stride,
                      'registers': {
                        for (final MapEntry(:key, :value)
                            in g.registers.entries)
                          '$key': [value.$1, value.$2],
                      },
                      'vertices': g.vertexCount,
                      'instances': g.instances,
                      if (g.indices case final i?) 'indices': putBlob(i),
                    },
                    final ScreenGeometry g => {
                      'vertices': g.vertexCount,
                      'instances': g.instances,
                    },
                  },
                  'state': {
                    'cull': d.state.cull,
                    'frontCCW': d.state.frontCounterClockwise,
                    'depthTest': d.state.depthTest,
                    'depthWrite': d.state.depthWrite,
                    'depthFunc': d.state.depthFunc,
                    'depthBias': [
                      d.state.depthBias,
                      d.state.slopeScaledDepthBias,
                      d.state.depthBiasClamp,
                    ],
                    'topology': d.state.topology,
                    if (d.state.stencil case final st?)
                      'stencil': {
                        'func': st.func,
                        'pass': st.passOp,
                        'read': st.readMask,
                        'write': st.writeMask,
                      },
                    'blends': [
                      for (final b in d.state.blends)
                        {
                          'on': b.enabled,
                          'color': b.color,
                          'alpha': b.alpha,
                          'mask': b.writeMask,
                        },
                    ],
                  },
                  'stencilRef': d.stencilRef,
                  'viewport': d.viewport,
                  'vs': res(d.vertexResources),
                  'ps': res(d.pixelResources),
                },
            ],
          },
          final DispatchPlan c => {
            'dispatch': c.name,
            'shader': c.shader,
            'groups': c.groups,
            if (c.indirect case final r?) 'indirect': _ref(r),
            'cs': res(c.resources),
          },
        },
    ],
  };
}

/// Reads the form of [planToJson] back. [blob] resolves a blob name. Fails
/// unless the plan has the tag [format].
FramePlan planFromJson(
  Map<String, Object?> j,
  Uint8List Function(String name) blob, {
  String format = framePlanFormat,
}) {
  if (j['format'] != format) {
    throw FormatException(
      'reading a frame plan: its format is ${j['format']}, not $format',
    );
  }
  List<double> nums(Object? l) => [
    for (final x in l as List) (x as num).toDouble(),
  ];
  List<String> strs(Object? l) => (l as List).cast<String>();
  StageResources res(Object? o) {
    final m = (o ?? const {}) as Map;
    return StageResources(
      blocks: {
        for (final MapEntry(:key, :value)
            in (m['blocks'] as Map? ?? {}).entries)
          key as String: blob(value as String),
      },
      textures: {
        for (final MapEntry(:key, :value)
            in (m['textures'] as Map? ?? {}).entries)
          key as String: switch (value as Map) {
            {'file': final String stem} => FileTexture(
              stem,
              srgb: value['srgb'] == true,
            ),
            {'target': final String t} => TargetTexture(
              t,
              mip: value['mip'] as int,
              mips: value['mips'] as int,
              layer: value['layer'] as int,
              layers: value['layers'] as int,
              srgb: value['srgb'] == true,
            ),
            {'buffer': final String b} => BufferTexture(
              blob(b),
              value['format'] as String,
            ),
            {'constant': final String b} => ConstantTexture(
              value['format'] as String,
              blob(b),
              type: value['type'] as String? ?? '2d',
              width: value['width'] as int?,
              height: value['height'] as int?,
            ),
            {'ref': final Map r} => BufferTextureRef(_refFrom(r)),
            _ => throw FormatException('texture $key: $value'),
          },
      },
      storage: {
        for (final MapEntry(:key, :value)
            in (m['storage'] as Map? ?? {}).entries)
          key as String: switch (value as Map) {
            {'inline': final String b} => InlineBuffer(
              blob(b),
              format: value['format'] as String?,
            ),
            {'image': final String t} => ImageRef(
              t,
              mip: value['mip'] as int? ?? 0,
              layer: value['layer'] as int? ?? 0,
            ),
            {'ref': final Map r} => _refFrom(r),
            _ => throw FormatException('storage $key: $value'),
          },
      },
      samplers: {
        for (final MapEntry(:key, :value)
            in (m['samplers'] as Map? ?? {}).entries)
          int.parse(key as String): () {
            final s = value as Map;
            final lod = nums(s['lod']);
            return SamplerState(
              minLinear: s['min'] as bool,
              magLinear: s['mag'] as bool,
              mipLinear: s['mip'] as bool,
              address: strs(s['address']),
              anisotropy: s['anisotropy'] as int,
              compare: s['compare'] as String?,
              minLod: lod[0],
              maxLod: lod[1],
              lodBias: lod[2],
              border: s['border'] as String? ?? 'transparentBlack',
            );
          }(),
      },
    );
  }

  Attachment att(Map a) => Attachment(
    a['target'] as String,
    mip: a['mip'] as int? ?? 0,
    layer: a['layer'] as int? ?? 0,
    clear: a['clear'] == null ? null : nums(a['clear']),
    clearDepth: (a['clearDepth'] as num?)?.toDouble(),
    clearStencil: a['clearStencil'] as int?,
    srgb: a['srgb'] == true,
  );
  final targets = {
    for (final MapEntry(:key, :value) in (j['targets'] as Map).entries)
      key as String: TargetSpec(
        value['width'] as int,
        value['height'] as int,
        value['format'] as String,
        layers: value['layers'] as int? ?? 1,
        mips: value['mips'] as int? ?? 1,
        samples: value['samples'] as int? ?? 1,
        storage: value['storage'] == true,
        volume: value['volume'] == true,
        initial: value['initial'] == null
            ? null
            : blob(value['initial'] as String),
      ),
  };
  final passes = <PassPlan>[];
  for (final p in (j['passes'] as List).cast<Map>()) {
    if (p['dispatch'] case final String name) {
      passes.add(
        DispatchPlan(
          name,
          p['shader'] as String,
          (p['groups'] as List).cast<int>(),
          res(p['cs']),
          indirect: p['indirect'] == null
              ? null
              : _refFrom(p['indirect'] as Map),
        ),
      );
      continue;
    }
    passes.add(
      RenderPassPlan(
        p['render'] as String,
        [for (final c in (p['colors'] as List).cast<Map>()) att(c)],
        p['depth'] == null ? null : att(p['depth'] as Map),
        [
          for (final d in (p['draws'] as List).cast<Map>())
            () {
              final g = d['geometry'] as Map;
              final s = d['state'] as Map;
              final bias = nums(s['depthBias'] ?? const [0, 0, 0]);
              return DrawPlan(
                label: d['label'] as String? ?? '',
                vertex: d['vertex'] as String,
                pixel: d['pixel'] as String?,
                geometry: g['inline'] != null
                    ? InlineGeometry(
                        blob(g['inline'] as String),
                        g['stride'] as int,
                        {
                          for (final MapEntry(:key, :value)
                              in (g['registers'] as Map).entries)
                            int.parse(key as String): (
                              (value as List)[0] as String,
                              value[1] as int,
                            ),
                        },
                        g['vertices'] as int,
                        instances: g['instances'] as int? ?? 1,
                        indices: g['indices'] == null
                            ? null
                            : blob(g['indices'] as String),
                      )
                    : g['mesh'] != null
                    ? DrawMeshGeometry(
                        g['mesh'] as String,
                        g['ibuffer'] as int,
                        g['first'] as int,
                        g['count'] as int,
                        instances: g['instances'] as int? ?? 1,
                        indirect: g['indirect'] == null
                            ? null
                            : _refFrom(g['indirect'] as Map),
                        streams: {
                          for (final MapEntry(:key, :value)
                              in (g['streams'] as Map? ?? const {}).entries)
                            int.parse(key as String): (
                              _refFrom((value as List)[0] as Map),
                              value[1] as int,
                              value[2] as String,
                            ),
                        },
                      )
                    : ScreenGeometry(
                        g['vertices'] as int,
                        instances: g['instances'] as int? ?? 1,
                      ),
                state: DrawState(
                  cull: s['cull'] as String,
                  frontCounterClockwise: s['frontCCW'] as bool? ?? false,
                  depthTest: s['depthTest'] as bool,
                  depthWrite: s['depthWrite'] as bool,
                  depthFunc: s['depthFunc'] as String,
                  depthBias: bias[0],
                  slopeScaledDepthBias: bias[1],
                  depthBiasClamp: bias[2],
                  topology: s['topology'] as String? ?? 'triangleList',
                  stencil: switch (s['stencil']) {
                    final Map st => Stencil(
                      func: st['func'] as String,
                      passOp: st['pass'] as String,
                      readMask: st['read'] as int,
                      writeMask: st['write'] as int,
                    ),
                    _ => null,
                  },
                  blends: [
                    for (final b in (s['blends'] as List).cast<Map>())
                      Blend(
                        enabled: b['on'] as bool,
                        color: strs(b['color']),
                        alpha: strs(b['alpha']),
                        writeMask: b['mask'] as int,
                      ),
                  ],
                ),
                stencilRef: d['stencilRef'] as int? ?? 0,
                viewport: nums(d['viewport']),
                vertexResources: res(d['vs']),
                pixelResources: res(d['ps']),
              );
            }(),
        ],
      ),
    );
  }
  return FramePlan(
    targets,
    passes,
    buffers: {
      for (final MapEntry(:key, :value)
          in (j['buffers'] as Map? ?? const {}).entries)
        key as String: BufferSpec(
          value['size'] as int,
          initial: value['initial'] == null
              ? null
              : blob(value['initial'] as String),
          readBack: value['readBack'] == true,
        ),
    },
  );
}
