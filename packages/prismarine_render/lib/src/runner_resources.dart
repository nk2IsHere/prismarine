part of 'frame_runner.dart';

/// The resources of the runner. They are inline vertices repacked for the
/// width of an input, target views typed as shaders declare them, constant
/// textures, buffers and target read-back.
extension RunnerResources on FrameRunner {
  /// Returns the vertices of [g] repacked for [shader]. Each input that it
  /// reads gets as many floats as it declares, the missing ones filled with
  /// the (0, 0, 0, 1) of Direct3D, since the engine fetches the declared
  /// width.
  (gpu.VertexLayout, Uint8List) _inlinePacked(
    ShaderRecord shader,
    InlineGeometry g,
    Set<String> dropped,
  ) {
    final inputs = [
      for (final a in shader.attributes)
        if (!dropped.contains(a.name))
          if (g.registers[a.register] case (final f, final offset))
            (a, f, offset),
    ];
    int width(String type) => switch (type) {
      'float' => 1,
      'vec2' => 2,
      'vec3' => 3,
      _ => 4,
    };
    final stride = inputs.fold(0, (n, x) => n + width(x.$1.type)) * 4;
    final vertices = g.bytes.length ~/ g.stride;
    final src = ByteData.sublistView(g.bytes);
    final out = ByteData(stride * vertices);
    final attrs = <gpu.VertexAttribute>[];
    var at = 0;
    for (final (a, f, offset) in inputs) {
      // Floats or unsigned normalized bytes.
      final (have, bytes) = switch (f) {
        'R32_FLOAT' => (1, false),
        'R32G32_FLOAT' => (2, false),
        'R32G32B32_FLOAT' => (3, false),
        'R32G32B32A32_FLOAT' => (4, false),
        'R8G8B8A8_UNORM' => (4, true),
        _ => throw UnsupportedError('no vertex format for $f'),
      };
      final n = width(a.type);
      for (var v = 0; v < vertices; v++) {
        for (var k = 0; k < n; k++) {
          final at0 = v * g.stride + offset;
          final x = k >= have
              ? (k == 3 ? 1.0 : 0.0)
              : bytes
              ? src.getUint8(at0 + k) / 255
              : src.getFloat32(at0 + 4 * k, Endian.little);
          out.setFloat32(v * stride + at + 4 * k, x, Endian.little);
        }
      }
      attrs.add(
        gpu.VertexAttribute(
          name: a.name,
          format: switch (n) {
            1 => gpu.VertexFormat.float32,
            2 => gpu.VertexFormat.float32x2,
            3 => gpu.VertexFormat.float32x3,
            _ => gpu.VertexFormat.float32x4,
          },
          offsetInBytes: at,
        ),
      );
      at += n * 4;
    }
    return (
      gpu.VertexLayout(
        buffers: [gpu.VertexBuffer(strideInBytes: stride, attributes: attrs)],
      ),
      out.buffer.asUint8List(),
    );
  }

  /// Fills the targets of the plan that take texels from the CPU
  /// (TargetSpec.initial), such as a lightmap solved on the CPU, from the
  /// bytes of this frame. It fills them layer by layer through [host] into
  /// [cb] before the passes of the frame. A target whose bytes are the object
  /// that it took last into the same texture is left as it is.
  void _uploadTargets(gpu.CommandBuffer cb, FramePlan plan, UniformRing host) {
    if (!identical(_uploadsOf, plan.targets)) {
      _uploadsOf = plan.targets;
      _uploadNames.clear();
      for (final MapEntry(:key, :value) in plan.targets.entries) {
        if (value.initial != null) _uploadNames.add(key);
      }
    }
    for (var i = 0; i < _uploadNames.length; i++) {
      final name = _uploadNames[i];
      final spec = plan.targets[name]!;
      final texture = targets[name]!;
      final bytes = plan.block(spec.initial!);
      final layer =
          spec.width * spec.height * texelBytes(pixelFormat(spec.format));
      if (bytes.length != layer * spec.layers) {
        if (_failedDraws.add('upload $name')) {
          warn?.call(
            'renderer: $name takes ${bytes.length} bytes, not '
            '${layer * spec.layers}; left as it was',
          );
        }
        continue;
      }
      final had = _uploaded[name];
      if (had != null &&
          identical(had.$1, bytes) &&
          identical(had.$2, texture)) {
        continue;
      }
      // alloc: a record per changed map
      _uploaded[name] = (bytes, texture);
      final at = host.emplace(bytes);
      for (var l = 0; l < spec.layers; l++) {
        // alloc: a view and a region per layer of a changed map
        cb.copyBufferToTexture(
          gpu.BufferView(
            at.buffer,
            offsetInBytes: at.offsetInBytes + l * layer,
            lengthInBytes: layer,
          ),
          gpu.TextureRegion(texture, slice: l),
        );
      }
    }
  }

  /// Copies the read-back buffers of the plan (BufferSpec.readBack) as this
  /// frame leaves them into RGBA8 textures of their bytes, at the end of the
  /// commands of the frame. Returns null when the plan has none.
  List<(String, gpu.Texture)>? _readBacks(
    gpu.CommandBuffer cb,
    FramePlan plan,
  ) {
    if (!identical(_readsOf, plan.buffers)) {
      _readsOf = plan.buffers;
      _readNames.clear();
      for (final MapEntry(:key, :value) in plan.buffers.entries) {
        if (value.readBack) _readNames.add(key);
      }
    }
    if (_readNames.isEmpty) return null;
    final out = <(String, gpu.Texture)>[];
    for (final name in _readNames) {
      final size = plan.buffers[name]!.size, texels = size >> 2;
      final w = texels < 4096 ? texels : 4096;
      final t = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        w,
        texels ~/ w,
        enableRenderTargetUsage: false,
      );
      cb.copyBufferToTexture(
        gpu.BufferView(_current[name]!, offsetInBytes: 0, lengthInBytes: size),
        gpu.TextureRegion(t),
      );
      out.add((name, t));
    }
    return out;
  }

  /// Passes the bytes of [reads] to [onReadBack] through the image of each
  /// texture.
  Future<void> _deliverReads(List<(String, gpu.Texture)> reads) async {
    for (final (name, t) in reads) {
      final img = t.asImage();
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null) continue;
      onReadBack?.call(
        name,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
  }

  /// Returns the texture file [f] for the shader type [type]. A file that the
  /// assets lack reads zeros, as an unbound Direct3D 11 view does. It is
  /// reported once. The frame still draws.
  gpu.Texture _file(FileTexture f, String type) {
    if (assets.hasTexture(f.stem)) return assets.texture(f.stem, srgb: f.srgb);
    if (_failedDraws.add('texture ${f.stem}')) {
      warn?.call(
        'renderer: no texture ${f.stem} in the assets; it reads zeros',
      );
    }
    return _constant(
      type.startsWith('u') ? 'R32G32B32A32_UINT' : 'R8G8B8A8_UNORM',
      Uint8List(type.startsWith('u') ? 16 : 4),
      type,
    );
  }

  gpu.Texture _texture(TextureRef? ref, String type) => switch (ref) {
    // The file textures of a plan are often the same objects from frame to
    // frame. The lookup by name runs once per object.
    final FileTexture f => _fileTextures[f] ??= _file(f, type),
    // The stencil of a depth target through a uint view, which the engine
    // cannot make, reads the copy of the runner (runner_stencil.dart). With
    // assets without the shaders of the copy it reads a stand-in with 0 in .y.
    final TargetTexture t
        when type.startsWith('u') &&
            isDepth(pixelFormat(_specs[t.target]!.format)) =>
      _stencilCopies[t.target] ??
          (_standIns['stencil $type'] ??= _constant(
            'R32_UINT',
            Uint8List.fromList([3, 0, 0, 0]),
            type,
          )),
    final TargetTexture t when t.srgb && _srgbCapable(t.target) => _srgbView(
      t.target,
    ),
    final TargetTexture t => _view(t, array: type.contains('Array')),
    // Per texel object and type, since the plans reuse their constant
    // textures.
    final ConstantTexture c => (_constantObjects[c] ??= {})[type] ??= switch ((
      c.width,
      c.height,
    )) {
      (final int w, final int h) => _image(c.format, c.texel, w, h),
      _ => _constant(c.format, c.texel, type),
    },
    _ => _standIns['zero $type'] ??= _constant(
      type.startsWith('u') ? 'R32G32B32A32_UINT' : 'R8G8B8A8_UNORM',
      Uint8List(type.startsWith('u') ? 16 : 4),
      type,
    ),
  };

  /// Returns a view of the mips and layers of [t], typed as the shader
  /// declares it. With [array] it is a 2D array, else a 2D texture of one
  /// layer.
  gpu.Texture _view(TargetTexture t, {required bool array}) {
    final base =
        targets[t.target] ?? (throw StateError('no target ${t.target}'));
    final spec = _specs[t.target]!;
    if (spec.volume || spec.samples > 1) return base;
    if (t.mip == 0 &&
        t.mips >= spec.mips &&
        t.layer == 0 &&
        t.layers >= spec.layers &&
        array == spec.layers > 1) {
      return base;
    }
    return _views['${t.target}|${t.mip}|${t.mips}|${t.layer}|${t.layers}|$array'] ??=
        base.makeView(
          baseMipLevel: t.mip,
          mipLevelCount: t.mips,
          baseLayer: t.layer,
          layers: t.layers,
          textureType: array
              ? gpu.TextureType.texture2DArray
              : gpu.TextureType.texture2D,
        );
  }

  gpu.Texture _constant(String format, Uint8List texel, String type) {
    final key = '$format|$type|${texel.join(',')}';
    return _constants[key] ??= () {
      final f = pixelFormat(format);
      final tt = switch (type) {
        'texture2DArray' || 'utexture2DArray' => gpu.TextureType.texture2DArray,
        'texture3D' || 'utexture3D' => gpu.TextureType.texture3D,
        _ => gpu.TextureType.texture2D,
      };
      final t = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        4,
        4,
        format: f,
        textureType: tt,
        enableRenderTargetUsage: false,
      );
      final px = Uint8List(16 * texel.length);
      for (var i = 0; i < 16; i++) {
        px.setRange(i * texel.length, (i + 1) * texel.length, texel);
      }
      t.overwrite(ByteData.sublistView(px));
      return t;
    }();
  }

  /// Returns a [w] × [h] 2D texture of [texels] in [format], one per texel
  /// object, such as a property map made from data.
  gpu.Texture _image(String format, Uint8List texels, int w, int h) {
    final t = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      w,
      h,
      format: pixelFormat(format),
      enableRenderTargetUsage: false,
    );
    t.overwrite(ByteData.sublistView(texels));
    return t;
  }

  /// Returns a device buffer with [bytes] for a written buffer that the plan
  /// does not read back. The host buffer is not for shader writes.
  gpu.BufferView _inline(Uint8List bytes) {
    final had = _inlineBuffers[bytes];
    if (had != null) {
      had.run = _runs;
      return had.view;
    }
    return _newInline(_inlineBuffers, bytes, 'buffer.inline');
  }

  // alloc-cold: a bytes object's first use as an inline buffer.
  gpu.BufferView _newInline(
    Map<Uint8List, _InlineBuffer> into,
    Uint8List bytes,
    String tag,
  ) {
    final view = _newBuffer(bytes.isEmpty ? Uint8List(16) : bytes, tag);
    into[bytes] = _InlineBuffer(view, _runs);
    return view;
  }

  // alloc-cold: a bytes object's first use as an inline buffer.
  /// Returns a device buffer with [bytes], counted under [tag] for the
  /// census.
  static gpu.BufferView _newBuffer(Uint8List bytes, String tag) {
    gpu.GpuMemory.tag = tag;
    final b = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(bytes),
    );
    gpu.GpuMemory.tag = null;
    return _whole(b);
  }

  static gpu.BufferView _whole(gpu.DeviceBuffer b) =>
      gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: b.sizeInBytes);

  /// Returns a vertex buffer with [bytes], one per bytes object.
  gpu.BufferView _inlineVertex(Uint8List bytes) {
    final had = _vertexBuffers[bytes];
    if (had != null) {
      had.run = _runs;
      return had.view;
    }
    return _newInline(_vertexBuffers, bytes, 'buffer.inlineVertex');
  }

  /// Returns [bytes] as the vertices or indices of a draw. Bytes get their own
  /// device buffer once the same object comes again in a later frame. Otherwise
  /// they get a view in the uniform ring of this frame. Bytes that a plan makes
  /// anew each frame take no buffer made for one frame.
  gpu.BufferView _drawBytes(
    Uint8List bytes,
    UniformRing host, {
    required bool vertex,
  }) {
    final own = vertex ? _vertexBuffers[bytes] : _inlineBuffers[bytes];
    final first = _firstRun[bytes];
    if (own != null || (first != null && first != _runs)) {
      return vertex ? _inlineVertex(bytes) : _inline(bytes);
    }
    _firstRun[bytes] ??= _runs;
    return _uniform(host, bytes, bytes.length);
  }

  /// Returns [bytes] for the input [input] of the dispatch [dispatch]. The
  /// bytes get the buffer of [_inline] once the same object comes again.
  /// Otherwise they overwrite the next of three buffers kept for that input. An
  /// input that the plan makes anew each frame reuses its buffers. Three
  /// buffers cover two frames on the GPU and one recording, as for the buffers
  /// of the plan. A name that comes twice in a frame keeps the buffer of its
  /// first use, since an overwrite would change what the first dispatch reads.
  gpu.BufferView _frameInline(String dispatch, String input, Uint8List bytes) {
    if (_inlineBuffers[bytes] != null) return _inline(bytes);
    // By dispatch and then input name, the same strings each frame.
    final at = (_inlineSlots[dispatch] ??= {})[input] ??= _InlineSlot();
    if (at.usedIn == _runs) return _inline(bytes);
    at.usedIn = _runs;
    final last = at.last;
    at.last = bytes;
    if (identical(last, bytes)) return _inline(bytes);
    final data = bytes.isEmpty ? Uint8List(16) : bytes;
    var v = at.ring[_frame];
    if (v == null || v.lengthInBytes != data.length) {
      // The last buffer of this frame slot, three runs old, goes now (G17).
      v?.buffer.prismarineRelease();
      gpu.GpuMemory.tag = 'buffer.perInput';
      v = at.ring[_frame] = _whole(
        gpu.gpuContext.createDeviceBuffer(
          gpu.StorageMode.hostVisible,
          data.length,
        ),
      );
      gpu.GpuMemory.tag = null;
    }
    v.buffer.overwrite(ByteData.sublistView(data));
    return v;
  }

  // alloc-cold: every 64 runs.
  /// Lets go of the plan buffers and inline texel slots that no run used in the
  /// last [_unnamedRuns] runs. A name that a plan stops using would otherwise
  /// keep its three host-visible buffers and its texel slot for good. The
  /// copies of a plan buffer take turns frame by frame. None carries anything
  /// that a later run reads.
  void _dropUnnamed() {
    final before = _runs - _unnamedRuns;
    var dropped = false;
    _bufferRun.removeWhere((name, run) {
      if (run >= before) return false;
      _buffers.remove(name)?.forEach(_release);
      _bufferSizes.remove(name);
      _current.remove(name);
      dropped = true;
      return true;
    });
    // The kept views of the buffers let go of them too.
    if (dropped) _bufferGen++;
    _inlineSlots.removeWhere((_, slots) {
      slots.removeWhere((_, s) => s.usedIn < before);
      return slots.isEmpty;
    });
    // The buffers of inline bytes that no run bound since go now, not when
    // a collection finds the bytes gone. A pass replayed natively keeps what
    // it bound. Bytes bound again later make a buffer again.
    _inlineBuffers.removeWhere(_unbound);
    _vertexBuffers.removeWhere(_unbound);
  }

  bool _unbound(Uint8List _, _InlineBuffer b) {
    if (b.run >= _runs - _unnamedRuns) return false;
    b.view.buffer.prismarineRelease();
    return true;
  }

  gpu.Texture _imageView(ImageRef i, {required bool array}) {
    final spec = _specs[i.target]!;
    if (spec.volume ||
        (i.mip == 0 &&
            i.layer == 0 &&
            spec.mips == 1 &&
            spec.layers == 1 &&
            !array)) {
      return targets[i.target]!;
    }
    // An array UAV covers the layers from its first one onward. The shader
    // selects the layer.
    return _view(
      TargetTexture(
        i.target,
        mip: i.mip,
        layer: i.layer,
        layers: array ? spec.layers - i.layer : 1,
      ),
      array: array,
    );
  }

  /// Returns the texels of the target [name] at [mip] and [layer] as
  /// stored. They are copied to a buffer and back into an RGBA8 texture of
  /// the same bytes, whose image Flutter reads without conversion.
  Future<Uint8List> readTarget(
    String name, {
    int mip = 0,
    int layer = 0,
  }) async {
    final t = targets[name]!;
    final w = t.width >> mip, h = t.height >> mip;
    final bpp = texelBytes(t.format);
    final bytes = w * h * bpp;
    final buf = gpu.gpuContext.createDeviceBuffer(
      gpu.StorageMode.devicePrivate,
      bytes,
    );
    // An RGBA8 texture as wide as the bytes of the row / 4.
    final rw = w * bpp ~/ 4;
    final rgba = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      rw,
      h,
      enableRenderTargetUsage: false,
    );
    final cb = gpu.gpuContext.createCommandBuffer();
    cb.copyTextureRegionToBuffer(
      t,
      buf,
      x: 0,
      y: 0,
      width: w,
      height: h,
      mipLevel: mip,
      slice: layer,
    );
    cb.copyBufferToTexture(
      gpu.BufferView(buf, offsetInBytes: 0, lengthInBytes: bytes),
      gpu.TextureRegion(rgba),
    );
    final done = Completer<bool>();
    gpuSubmitted();
    cb.submit(completionCallback: done.complete);
    await done.future;
    final img = rgba.asImage();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

/// The number of runs that a plan buffer or inline texel slot may go unused
/// before the runner lets it go (RunnerResources._dropUnnamed).
const _unnamedRuns = 8;

/// Lets go of the copy [b] of a plan buffer at once (G17).
void _release(gpu.DeviceBuffer b) => b.prismarineRelease();

/// The view of an inline buffer and the run that bound it last.
final class _InlineBuffer {
  _InlineBuffer(this.view, this.run);
  final gpu.BufferView view;
  int run;
}

final class _InlineSlot {
  Uint8List? last;
  int usedIn = -1;
  final ring = List<gpu.BufferView?>.filled(3, null);
}
