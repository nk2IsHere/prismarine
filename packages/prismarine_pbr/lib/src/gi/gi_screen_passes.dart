part of 'gi_passes.dart';

/// The render passes of the indirect light after the opaque pass.
extension GiScreenPasses on GiPasses {
  // alloc-cold: a new plan.
  /// The passes after the opaque pass into [hdr] with depth [depth]. [frame]
  /// is the block of the frame role and [view] the viewport of the plan.
  List<RenderPassPlan> after(
    Uint8List frame,
    String hdr,
    String depth,
    List<double> view,
  ) {
    final indirect = role.block;
    final half = <double>[
      0,
      0,
      ((_width + 1) ~/ 2).toDouble(),
      ((_height + 1) ~/ 2).toDouble(),
      0,
      1,
    ];
    DrawPlan screen(
      String pixel,
      List<double> viewport,
      Map<String, TextureRef> textures, {
      DrawState state = _screenState,
      String vertex = _screenVertex,
      String label = '',
    }) => DrawPlan(
      vertex: vertex,
      pixel: pixel,
      geometry: InlineGeometry(_triangle, 8, const {0: ('R32G32_FLOAT', 0)}, 3),
      state: state,
      viewport: viewport,
      vertexResources: StageResources(),
      pixelResources: StageResources(
        blocks: {'Frame': frame, 'Indirect': indirect},
        textures: textures,
        samplers: GiPasses.samplers,
      ),
      label: label.isEmpty ? pixel : label,
    );
    final gbuffer = {
      'depth': TargetTexture(depth),
      'gbufferNormal': const TargetTexture(GiTargets.gbufferNormal),
    };
    final passes = <RenderPassPlan>[];
    if (settings.sky) {
      passes.add(
        RenderPassPlan(
          'sky',
          [Attachment(hdr)],
          Attachment(depth),
          [
            screen(
              _skyPixel,
              view,
              textures,
              state: _skyState,
              vertex: _skyVertex,
            ),
          ],
        ),
      );
    }
    if (settings.ambientOcclusion) {
      passes
        ..add(
          RenderPassPlan(
            'ao',
            const [Attachment(GiTargets.aoRaw)],
            null,
            [screen(_aoPixel, half, gbuffer)],
          ),
        )
        ..add(
          RenderPassPlan(
            'aoBlur',
            const [Attachment(GiTargets.ao)],
            null,
            [
              screen(_aoBlurPixel, half, {
                'depth': TargetTexture(depth),
                'aoRaw': const TargetTexture(GiTargets.aoRaw),
              }),
            ],
          ),
        );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'ssr',
          const [
            Attachment(GiTargets.ssr, clear: [0, 0, 0, 0]),
          ],
          null,
          [
            screen(_ssrPixel, settings.ssrFullSize ? view : half, {
              ...gbuffer,
              'history': const TargetTexture(
                GiTargets.history,
                mips: _historyMips,
              ),
            }),
          ],
        ),
      );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'ssrBlur',
          const [Attachment(GiTargets.ssrBlur)],
          null,
          [
            screen(_ssrBlurPixel, settings.ssrFullSize ? view : half, {
              'depth': TargetTexture(depth),
              'ssrRaw': const TargetTexture(GiTargets.ssr),
            }),
          ],
        ),
      );
    }
    passes.add(
      RenderPassPlan(
        'giResolve',
        const [
          Attachment(GiTargets.giDiffuseHalf),
          Attachment(GiTargets.giSpecularHalf),
        ],
        null,
        [
          screen(_resolvePixel, half, {...gbuffer, ...textures}),
        ],
      ),
    );
    final debug = settings.debugView;
    final replace = debug != GiDebugView.none && debug != GiDebugView.probes;
    passes.add(
      RenderPassPlan(
        'indirect',
        [Attachment(hdr)],
        null,
        [
          screen(_indirectPixel, view, {
            ...gbuffer,
            'gbufferAlbedo': const TargetTexture(GiTargets.gbufferAlbedo),
            'ao': settings.ambientOcclusion
                ? const TargetTexture(GiTargets.ao)
                : _white,
            'ssr': settings.reflections
                ? const TargetTexture(GiTargets.ssrBlur)
                : _black,
            'giDiffuseHalf': const TargetTexture(GiTargets.giDiffuseHalf),
            'giSpecularHalf': const TargetTexture(GiTargets.giSpecularHalf),
            'brdfLut': const TargetTexture(GiTargets.brdfLut),
          }, state: replace ? _screenState : _addState),
        ],
      ),
    );
    if (debug == GiDebugView.probes && volume != null) {
      passes.add(
        RenderPassPlan(
          'probes',
          [Attachment(hdr)],
          Attachment(depth),
          [
            DrawPlan(
              vertex: _probeVertex,
              pixel: _probePixel,
              geometry: InlineGeometry(
                _quad,
                8,
                const {0: ('R32G32_FLOAT', 0)},
                6,
                instances: volume!.probeCount,
              ),
              state: const DrawState(cull: 'none'),
              viewport: view,
              vertexResources: StageResources(
                blocks: {'Frame': frame, 'Indirect': indirect},
                textures: {'giProbes': textures['giProbes']!},
              ),
              pixelResources: StageResources(
                blocks: {'Indirect': indirect},
                textures: {
                  'giIrradiance': const TargetTexture(GiTargets.giIrradiance),
                },
                samplers: GiPasses.samplers,
              ),
              label: 'probes',
            ),
          ],
        ),
      );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'history',
          const [Attachment(GiTargets.history)],
          null,
          [
            screen(_downsamplePixel, half, {'source': TargetTexture(hdr)}),
          ],
        ),
      );
      for (var m = 1; m < _historyMips; m++) {
        final w = math.max(1, ((_width + 1) ~/ 2) >> m);
        final h = math.max(1, ((_height + 1) ~/ 2) >> m);
        passes.add(
          RenderPassPlan(
            'historyMip$m',
            [Attachment(GiTargets.history, mip: m)],
            null,
            [
              screen(
                _downsamplePixel,
                [0, 0, w.toDouble(), h.toDouble(), 0, 1],
                {'source': TargetTexture(GiTargets.history, mip: m - 1)},
              ),
            ],
          ),
        );
      }
    }
    firstAfter = passes.first.name;
    return passes;
  }
}
