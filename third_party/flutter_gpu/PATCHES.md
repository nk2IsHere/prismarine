# flutter_gpu (Dart side), vendored

Flutter GPU's Dart package (`engine/src/flutter/lib/gpu/lib` + `pubspec.yaml`, BSD, © The Flutter Authors, `LICENSE`) at our engine's revision `deb287481e` (identical to `data/flutter/bin/cache/pkg/flutter_gpu`), patched for perf E. `apps/mcsm_player` uses it through `dependency_overrides`; flutter_scene and the rest resolve to it from there. Its `@Native` functions resolve by symbol through the process (Flutter GPU sets no native resolver), so the copy binds to the running engine's exports.

To see every change: `diff -ru $MCSM_FLUTTER/bin/cache/pkg/flutter_gpu/lib third_party/flutter_gpu/lib`. Each patch is marked `mcsm G<n>`.

## G1: engine detection

`natives.dart`: `_mcsmEngineE3` is whether the process exports `InternalFlutterGpu_RenderPass_BindUniformIndexed` (third_party/flutter_engine patch 0003). With Flutter's prebuilt engine it's false and every call below takes the stock path, so the app runs on either engine.

## G2: binds by resolved slot index

- `shader.dart`: a `UniformSlot` resolves its name once per use as a struct and as a texture (`Shader._resolveUniformStruct/_resolveUniformTexture`, one Handle call each). flutter_scene caches slots per shader and name (`cachedUniformSlot`), so a draw's binds no longer send a Dart string.
- `buffer.dart` (`_bindAsUniform`) and `render_pass.dart` (`bindTexture`) call `_bindUniformIndexed` / `_bindTextureIndexed` as leaf calls. They fail exactly where the name lookup failed: an unknown name resolves to -1 and throws the same exception.

## G3: leaf calls

- `drawIndexed`/`draw` first try `_drawCached` (leaf): it draws when the pass already has the pipeline. If not, it returns 2 and does nothing, and the stock non-leaf draw runs, which may wait for a Metal pipeline compile. A leaf call never blocks, so the sim and audio isolates' safepoints never wait on it.
- `_bindVertexBufferDevice`, `_bindIndexBufferDevice` and `_clearBindings` are leaf calls: no Dart handles and nothing that blocks (also on the stock engine).

## G4: live GPU memory (accounting only)

- `memory.dart` (new, `GpuMemory`): every texture and device buffer made through the package adds its bytes to a tally by kind (`buffer`; `rt`, `rt.msaa`, `rt.transient`; `tex.shared` / `tex.private`, `.compressed` when block-compressed); a `Finalizer` takes a collected one off. `texture.dart` computes a texture's bytes from its format's blocks, mip levels and sample count (the driver's padding isn't counted). The player's `--profile` writes it every 30 frames as `mem.gpu.<kind>` (MB) with `mem.footprint`. It excludes what the engine allocates itself (the Flutter surface, Impeller's host buffers).

## G5: repeated texture binds skipped

`render_pass.dart`: a pass remembers, per shader and resolved texture slot, the texture and sampler object it bound since the last `clearBindings` (bindings persist across draws until then, on every backend). Binding the same pair again returns before the native call: flutter_scene and mcsm's encoders rebind every slot per draw, and consecutive draws mostly share the shadow atlas, the occlusion buffer, placeholders and the block atlas. Only with the perf E engine (the indexed bind); the stock path is unchanged.

## G6: cheaper calls per draw (mcsm7)

- `render_pass.dart`: the pipeline-state setters (`bindPipeline`, blend, depth, stencil, scissor, viewport, cull, winding, primitive, polygon mode) are leaf calls: they only store state natively (also on the stock engine).
- A pass remembers the pipeline, cull mode, winding, primitive type and polygon mode it set last; setting the same again doesn't cross into the engine (flutter_scene sets winding and primitive type before every draw).
- G5's memo lives on the `Shader` (the pass and its clear number it holds bindings for, then the texture and sampler per index) instead of a per-pass identity map: no hash lookup per texture bind.

## G7: draws from a first instance (mcsm7)

- `render_pass.dart`: `draw` and `drawIndexed` take `firstInstance` (default 0): every instance-rate vertex buffer starts at that instance, as if its view were bound `firstInstance` elements further on; the shader's instance index still counts from 0. On the mcsm7 engine (`InternalFlutterGpu_RenderPass_McsmDrawInstanced`, patch 0012) it is one leaf call; on other engines, or before the pass has built the pipeline, the instance-rate slots are bound again at the offset for that draw and then restored (the pass remembers each slot's view; the pipeline its `VertexLayout`).
- `render_pipeline.dart`: a `RenderPipeline` keeps the `VertexLayout` it was made with.
- gpu_smoke checks it against offset bindings (plain and indexed: 0 px differ) on the stock, mcsm6 and mcsm7 engines.

## G8: GpuMemory.totalBytes (perf4)

- `memory.dart`: the sum of G4's bytes, kept as objects are made and finalized (no map per read): the player's GC pacing reads it once a frame.

## G9: S2's additions (mcsm9)

- `formats.dart`: `PixelFormat` gains the formats Metal and Vulkan share (R11G11B10 float, RGB9E5, RGBA16 unorm and snorm, D16, D32 float, 8/16/32-bit integer and signed-normalized formats, RGB10A2, R16/RG16/RG32 float, BC2, BC4, BC5 signed, BC6H), after the stock values as the engine's enum, with their block sizes; `TextureType` gains `texture2DArray` and `texture3D`.
- `texture.dart`, `context.dart`: `createTexture(…, layers:, depth:)`; a layered texture, an added format or a sample count of 2 goes through `InternalFlutterGpu_Texture_McsmInitializeLayered` (throws on an engine without it); `sliceCount` is an array's layers and a 3D texture's depth, so `overwrite(slice:)` and `CommandBuffer.copyBufferToTexture` upload one layer or depth slice; `Texture.makeView(baseMipLevel:, mipLevelCount:, baseLayer:, layers:)` (`InternalFlutterGpu_Texture_McsmInitializeView`) is a view sharing the texture's memory, to render into one level while sampling another or treat one layer as a 2D target; G4 counts layers and depth, not views.
- `compute.dart` (new): `mcsmEngineSupportsS2` (engine bit 2048); `Shader.getStorageBufferSlot` / `getStorageImageSlot` (a storage buffer by its block's type name, an image by its variable name); `RenderPass.bindStorageBuffer` (sent at each draw, not recorded into draw lists) and `RenderPass.drawIndirect`; `GpuContext.createComputePipeline`, `CommandBuffer.createComputePass` and `ComputePass` (`bindPipeline`, `bindUniform`, `bindStorageBuffer`, `bindTexture`, `bindStorageImage`, `dispatch(x, y, z)`, `dispatchIndirect`, `barrier`; resources are bound again after each dispatch).
- `natives.dart`: `_mcsmEngineS2`, whether the engine exports `InternalFlutterGpu_ComputePass_McsmDispatch`.
- gpu_smoke's mcsm9 checks use all of it on Metal and Vulkan.

## G10: S2's binds and dispatches as leaf calls

- `compute.dart`: every `ComputePass` bind, `dispatch`, `dispatchIndirect` and `barrier`, and the render pass's separate texture, separate sampler, texel buffer, storage buffer and texture-with-sampler binds are leaf calls: the engine's halves only store or encode state (no Dart handles, nothing that waits), as G3's and G6's do. S2's heavy shots make thousands of them a frame (BeaconTown's title shot: ~855 dispatches with about six binds each).
- `drawIndirect` stays a non-leaf call: like the stock draw, it may wait for a pipeline the pass has not built yet.

## Measured

See `third_party/flutter_engine/README.md` and status-perf ("E").
