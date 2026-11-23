// The frame history: the last few seconds of shown frames, each the 3D image with the UI
// scenes drawn over it, downscaled on the GPU into a ring the review
// scrubs. Nothing is read back while playing.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'issue.dart';

/// The full-screen copy that the history draws its frames with: a pipeline
/// of a vertex stage that draws two triangles from 2D clip-space positions
/// and a fragment stage that samples [source].
abstract interface class FrameCopy {
  gpu.RenderPipeline get pipeline;
  gpu.UniformSlot get source;
}

class FrameHistory {
  /// [seconds] of frames at up to 120 a second (a new frame per display
  /// refresh, 120 Hz on ProMotion screens); textures are made as the ring
  /// fills.
  FrameHistory({
    double seconds = 3,
    this.width = 640,
    this.height = 360,
    required this.copy,
  }) : capacity = (seconds * 120).ceil();

  final FrameCopy copy;

  /// How many frames the ring holds (0: off).
  final int capacity;

  /// The ring's frame size (16:9 by default).
  final int width, height;

  bool get enabled => capacity > 0;

  late final RingIndex _ring = RingIndex(capacity > 0 ? capacity : 1);
  late final List<gpu.Texture?> _textures = List.filled(capacity, null);
  late final List<HistoryMeta?> _meta = List.filled(capacity, null);

  /// While true (the review is open) no frame is added.
  bool frozen = false;

  /// The slot the current paint writes into (its UI layers blend over it),
  /// or null between paints and for a frame that isn't kept.
  int? _open;

  /// How many frames the ring holds now.
  int get length => enabled ? _ring.length : 0;

  /// The frame [back] frames before the newest (0 = newest).
  HistoryMeta metaAt(int back) => _meta[_ring.slotAt(back)]!;

  /// The frame [back] frames before the newest as an image (a new handle:
  /// the caller disposes it).
  ui.Image imageAt(int back) => _textures[_ring.slotAt(back)]!.asImage();

  /// Called once a kept frame is whole (its UI layers blended): when the
  /// next paint starts. [seq] counts the kept frames, so two consecutive
  /// [seq]s were shown one after the other (the glitch catcher's input).
  void Function(int seq, gpu.Texture frame, HistoryMeta meta)? onFrameDone;
  int _seq = 0;

  /// After the 3D scene rendered: closes the frame the last paint opened.
  /// Returns whether a new frame, described by [meta], is kept; [add] then
  /// takes its image. [meta] is null when the frame repeats the last one
  /// (paced, held, paused).
  bool painted(HistoryMeta? meta) {
    if (_open case final open? when onFrameDone != null) {
      onFrameDone!(_seq++, _textures[open]!, _meta[open]!);
    }
    // While the review is open the shown frames aren't kept: the next kept
    // one doesn't follow the last.
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

  /// After a UI scene rendered over the frame: its image [src] blended over
  /// the frame [add] opened.
  void paintedLayer(gpu.Texture? src) {
    final slot = _open;
    if (slot == null) return;
    if (src == null) return;
    _blit(src, _textures[slot]!, blend: true);
  }

  /// Frees the ring's textures.
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

  /// [src] scaled into [dst]: replacing it, or (UI layers, premultiplied)
  /// blended over it.
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
