# flutter_gpu, the Dart side, vendored

This is the Dart package of Flutter GPU, `engine/src/flutter/lib/gpu/lib` with its `pubspec.yaml`, at the engine
revision `deb287481e` of the patched engine. It is BSD licensed, © The Flutter Authors, see `LICENSE`. An app uses it
through `dependency_overrides`, and every package of the app then resolves to it. Its `@Native` functions resolve by
symbol through the process, since Flutter GPU sets no native resolver. The copy therefore binds to the exports of the
running engine, and on the prebuilt engine of Flutter every patched call takes the stock path.

`diff -ru <Flutter SDK>/bin/cache/pkg/flutter_gpu/lib third_party/flutter_gpu/lib` shows every change. Each patch is
marked `mcsm G<n>` in the code. The engine patches are in [the engine README](../flutter_engine/README.md).

## G1: engine detection

`natives.dart` has `_mcsmEngineE3`, which is true when the process exports
`InternalFlutterGpu_RenderPass_BindUniformIndexed` of engine patch 0003. On the prebuilt engine of Flutter it is false
and every call below takes the stock path.

## G2: binds by resolved slot index

- `shader.dart` resolves the name of a `UniformSlot` once per use as a struct and as a texture, with one Handle call
  each. A caller that keeps the slots per shader and name sends no Dart string per bind.
- `_bindAsUniform` of `buffer.dart` and `bindTexture` of `render_pass.dart` call `_bindUniformIndexed` and
  `_bindTextureIndexed` as leaf calls. They fail exactly where the name lookup failed. An unknown name resolves to -1
  and throws the same exception.

## G3: leaf calls

- `drawIndexed` and `draw` first try the leaf call `_drawCached`, which draws when the pass already has the pipeline.
  It returns 2 and does nothing otherwise, and the stock draw runs, which may wait for a Metal pipeline compile. A leaf
  call does not block, so the safepoints of other isolates do not wait on it.
- `_bindVertexBufferDevice`, `_bindIndexBufferDevice` and `_clearBindings` are leaf calls on every engine.

## G4: live GPU memory

`memory.dart` has `GpuMemory`. Every texture and device buffer made through the package adds its bytes to a tally by
kind: `buffer`, `rt`, `rt.msaa`, `rt.transient`, `tex.shared` and `tex.private`, with `.compressed` for block
compression. A `Finalizer` takes a collected one off. `texture.dart` computes the bytes of a texture from the blocks of
its format, its mip levels and its sample count, without the padding of the driver. The tally leaves out what the
engine allocates itself, such as the Flutter surface and the host buffers of Impeller. `GpuMemory.tag` gives the kind
that buffers made meanwhile count under, as `buffer.<owner>`.

## G5: repeated texture binds skipped

`render_pass.dart` remembers, per shader and resolved texture slot, the texture and sampler that a pass bound since the
last `clearBindings`. Bindings persist across draws until then on every backend. Binding the same pair again returns
before the native call. This applies on the patched engine only, with the indexed bind.

## G6: cheaper calls per draw

- The pipeline-state setters of `render_pass.dart` are leaf calls on every engine: `bindPipeline`, blend, depth,
  stencil, scissor, viewport, cull, winding, primitive and polygon mode. They only store state natively.
- A pass remembers the pipeline, cull mode, winding, primitive type and polygon mode that it set last. Setting the same
  again does not cross into the engine.
- The memo of G5 is on the `Shader`, with the pass and its clear number and then the texture and sampler per index, in
  place of a map per pass.

## G7: draws from a first instance

- `draw` and `drawIndexed` of `render_pass.dart` take `firstInstance`, 0 by default. Every instance-rate vertex buffer
  starts at that instance, and the instance index of the shader still counts from 0. Engine patch 0012
  (`InternalFlutterGpu_RenderPass_McsmDrawInstanced`) makes it one leaf call. On other engines, or before the pass has
  built the pipeline, the instance-rate slots are bound again at the offset for that draw and then restored.
- A `RenderPipeline` of `render_pipeline.dart` keeps the `VertexLayout` it was made with.
- gpu_smoke checks it against offset bindings, plain and indexed.

## G8: GpuMemory.totalBytes

`memory.dart` keeps the sum of the bytes of G4 up to date as objects are made and finalized.

## G9: formats, layered textures and compute

- `PixelFormat` of `formats.dart` gains the formats that Metal and Vulkan share, after the stock values as in the enum
  of the engine, with their block sizes: R11G11B10 float, RGB9E5, RGBA16 unorm and snorm, D16, D32 float, 8, 16 and
  32-bit integer and signed-normalized formats, RGB10A2, R16, RG16 and RG32 float, BC2, BC4, BC5 signed and BC6H.
  `TextureType` gains `texture2DArray` and `texture3D`.
- `createTexture` of `texture.dart` and `context.dart` takes `layers` and `depth`. A layered texture, an added format or
  a sample count of 2 goes through `InternalFlutterGpu_Texture_McsmInitializeLayered` and throws on an engine without
  it. `sliceCount` is the layer count of an array and the depth of a 3D texture, so `overwrite(slice:)` and
  `CommandBuffer.copyBufferToTexture` upload one layer or depth slice. `Texture.makeView` makes a view that shares the
  memory of the texture, to render into one level while another is sampled or to use one layer as a 2D target. G4
  counts layers and depth and does not count views.
- `compute.dart` has `mcsmEngineSupportsS2`, engine bit 2048. `Shader.getStorageBufferSlot` finds a storage buffer by
  the type name of its block and `getStorageImageSlot` an image by its variable name. `RenderPass.bindStorageBuffer` is
  sent at each draw and is not recorded into draw lists. It also has `RenderPass.drawIndirect`,
  `GpuContext.createComputePipeline`, `CommandBuffer.createComputePass` and `ComputePass` with `bindPipeline`,
  `bindUniform`, `bindStorageBuffer`, `bindTexture`, `bindStorageImage`, `dispatch`, `dispatchIndirect` and `barrier`.
  Resources are bound again after each dispatch.
- `natives.dart` has `_mcsmEngineS2`, true when the engine exports `InternalFlutterGpu_ComputePass_McsmDispatch`.
- The release 9 checks of gpu_smoke use all of it on Metal and Vulkan.

## G10: binds and dispatches as leaf calls

- Every bind, `dispatch`, `dispatchIndirect` and `barrier` of a `ComputePass` in `compute.dart` is a leaf call. The
  same holds for the separate texture, separate sampler, texel buffer, storage buffer and texture-with-sampler binds of
  a render pass. The native halves only store or encode state. A frame with many compute passes makes thousands of
  these calls, such as about 855 dispatches with about six binds each.
- `drawIndirect` stays a non-leaf call, since it may wait for a pipeline that the pass has not built yet.

## G11: native pointers of wrapper objects read once

- `_mcsmPointerOf(o)` of `natives.dart` returns the native field of an object as a `Pointer<Void>`, through libc
  `memmove(p, p, 0)`. `RenderPass`, `ComputePass`, `DeviceBuffer`, `Shader`, `Texture`, `RenderPipeline` and
  `ComputePipeline` keep theirs in `_mcsmSelf`, read on first use.
- In `render_pass.dart`, `compute.dart` and `compute_natives.dart`, every leaf native that took a wrapper object is a
  static native that takes `Pointer<Void>`s. A method of the old name calls it with the kept pointers. A wrapper passed
  to a native call becomes a new `Pointer` object on each call unless the generated call is inlined, which an AOT build
  does not do. Non-leaf natives keep the wrappers, since their generated calls hold the objects alive through a
  collection inside the call.

## G12: the set-up of a render pass by kept pointers

The non-leaf natives that make a `RenderPass` in `render_pass.dart`, `SetColorAttachment`, `SetDepthStencilAttachment`
and `Begin`, are static natives that take `Pointer<Void>`s for the pass, the context, the textures of the attachments
and the command buffer. `GpuContext` and `CommandBuffer` keep their `_mcsmSelf` too. The constructor holds every
wrapper through each call, so none can be collected inside one.

## G13: vertex views made on first bind

The per-slot vertex views of G7 in `render_pass.dart` are a list made on the first `bindVertexBuffer` of a pass.

## G14: one vertex view list for every pass

The list of vertex views of G13 is one static list, held by the pass that bound a vertex buffer last. A pass binds and
draws before the next one binds. A draw from a first instance on the fallback path reads its views only while its pass
holds the list and throws otherwise.

## G15: passes and command buffers made again, collections at an idle point

- `natives.dart` has `_mcsmEngine11`, true when the process exports `InternalFlutterGpu_McsmDetach` of engine patch
  0028. `mcsmGcIdleSupported` and `mcsmGcIdle(budgetMicros, minNewBytes, maxNewBytes)` run the collections of the Dart
  VM at the idle point of the caller. On other engines they return 0 and do nothing.
- At `submit` a command buffer of `command_buffer.dart` detaches its render and compute passes and itself from their
  native objects with `_mcsmDetach`. The native objects are released there, and no weak handle is left for a
  collection to finalize. The Dart objects go into the free lists of the context. `createCommandBuffer`,
  `createRenderPass` and `createComputePass` take one from there and initialize it again with `_mcsmAgain` and
  `_mcsmSetup`. `_mcsmSelf` is read again and is not final. A pass made again counts its clear number on, so the
  bound-texture memo of G5 from the pass before does not match. Without the export nothing is reused.
- A command buffer or a pass must not be used after its submit, since the object is another pass by then.

## G16: compaction on request, the figures of the heap

- `natives.dart` has `_mcsmEngine12`, true when the process exports `InternalFlutterGpu_McsmOldSpace` of engine patch
  0029 with the Dart patch `dart/0003`. `mcsmOldSpace(request)` with 1 starts an old-space mark now and with 2 runs a
  young collection and a mark-compact with the page cache of the VM emptied. `mcsmHeap(which)` returns the old space
  used, its capacity and its external size, and the new space used and its capacity, in bytes. On other engines they
  return 0 and -1, and `mcsmOldSpaceSupported` is false.
- The old space of the VM does not shrink without compaction. The incremental compactor moves at most a quarter of new
  space per mark, from pages that are at most half full, and a release engine has no call that compacts or reads the
  heap.

## G17: a device buffer released when its owner drops it

- `DeviceBuffer.mcsmRelease()` of `buffer.dart` detaches the wrapper from its native buffer at once with the export of
  G15, so the GPU memory goes now and not when a collection finalizes the object. `memory.dart` takes it off the tally
  of G4. The finalizer is attached with the object as its detach key. Without the export it does nothing.
- The GPU memory of a buffer carries no external size. The VM does not see it, and dropped buffers waited for the next
  old-space mark-sweep.
- Frames already submitted keep what they bound. Metal command buffers retain their resources and Vulkan ones track
  them. The object and its views must not be used again.
