// The frame history keeps the last few seconds of shown frames in a ring for
// the review. Each frame is the 3D image with the UI scenes drawn over it,
// downscaled on the GPU. Nothing is read back while the game runs.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'issue.dart';

/// A full-screen copy for the frame history. The vertex stage of [pipeline]
/// draws two triangles from 2D clip-space positions. Its fragment stage
/// samples [source].
abstract interface class FrameCopy {
  gpu.RenderPipeline get pipeline;
  gpu.UniformSlot get source;
}

class FrameHistory {
  /// Keeps [seconds] of frames at up to 120 frames a second, one frame per
  /// display refresh, in frames of [width] by [height]. [copy] draws each
  /// frame into the ring. The textures are made as the ring fills.
  FrameHistory({
    double seconds = 3,
    this.width = 640,
    this.height = 360,
    required this.copy,
  }) : capacity = (seconds * 120).ceil();

  final FrameCopy copy;

  /// The number of frames that the ring holds, 0 when it is off.
  final int capacity;

  /// The frame size of the ring, 16:9 by default.
  final int width, height;

  bool get enabled => capacity > 0;

  late final RingIndex _ring = RingIndex(capacity > 0 ? capacity : 1);
  late final List<gpu.Texture?> _textures = List.filled(capacity, null);
  late final List<HistoryMeta?> _meta = List.filled(capacity, null);

  /// No frame is added while this is true, such as while the review is open.
  bool frozen = false;

  /// The slot of the current paint, which its UI layers blend over. Null
  /// between paints and for a frame that is not kept.
  int? _open;

  /// The number of frames in the ring now.
  int get length => enabled ? _ring.length : 0;

  /// Returns the frame [back] frames before the newest, where 0 is the
  /// newest.
  HistoryMeta metaAt(int back) => _meta[_ring.slotAt(back)]!;

  /// Returns the frame [back] frames before the newest as an image. The
  /// image is a new handle that the caller disposes.
  ui.Image imageAt(int back) => _textures[_ring.slotAt(back)]!.asImage();

  /// Receives each kept frame once it is whole with its UI layers blended,
  /// when the next paint starts. [seq] counts the kept frames. Two frames
  /// with consecutive [seq] values were shown one after the other.
  void Function(int seq, gpu.Texture frame, HistoryMeta meta)? onFrameDone;
  int _seq = 0;

  /// Closes the frame that the last paint opened, after the 3D scene
  /// rendered. Returns whether a new frame described by [meta] is kept.
  /// [add] then takes its image. [meta] is null for a frame that repeats the
  /// last one, such as a paced, held or paused one.
  bool painted(HistoryMeta? meta) {
    if (_open case final open? when onFrameDone != null) {
      onFrameDone!(_seq++, _textures[open]!, _meta[open]!);
    }
    // While the review is open the shown frames are not kept. The next kept
    // frame does not follow the last one.
    if (frozen) _seq++;
    _open = null;
    return enabled && !frozen && meta != null;
  }

  /// Adds [src], the image of the frame that [painted] kept, described by
  /// [meta].
  void add(gpu.Texture? src, HistoryMeta meta) {
    if (src == null) return;
    final slot = _ring.push();
    final dst = _textures[slot] ??= gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: src.format,
      enableShaderReadUsage: true,
      enableRenderTargetUsage: true,
    );
    _meta[slot] = meta;
    _blit(src, dst, blend: false);
    _open = slot;
  }

  /// Blends [src], the image of a UI scene drawn over the frame, over the
  /// frame that [add] opened.
  void paintedLayer(gpu.Texture? src) {
    final slot = _open;
    if (slot == null) return;
    if (src == null) return;
    _blit(src, _textures[slot]!, blend: true);
  }

  /// Frees the textures of the ring.
  void clear() {
    _ring.clear();
    _textures.fillRange(0, capacity, null);
    _meta.fillRange(0, capacity, null);
    _open = null;
  }

  static final gpu.BufferView _quad = gpu.BufferView(
    gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList(const [
          -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, //
          -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, //
        ]),
      ),
    ),
    offsetInBytes: 0,
    lengthInBytes: 6 * 2 * 4,
  );
  static final gpu.SamplerOptions _linear = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  /// Draws [src] scaled into [dst]. With [blend] it is blended over [dst] as
  /// a premultiplied UI layer, else it replaces [dst].
  void _blit(gpu.Texture src, gpu.Texture dst, {required bool blend}) {
    final cb = gpu.gpuContext.createCommandBuffer();
    final pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: dst,
          loadAction: blend ? gpu.LoadAction.load : gpu.LoadAction.clear,
        ),
      ),
    );
    pass.bindPipeline(copy.pipeline);
    pass.setColorBlendEnable(blend);
    if (blend) pass.setColorBlendEquation(gpu.ColorBlendEquation());
    pass.bindVertexBuffer(_quad);
    pass.bindTexture(copy.source, src, sampler: _linear);
    pass.draw(6);
    cb.submit();
  }
}
