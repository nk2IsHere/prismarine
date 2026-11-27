# prismarine_frame

The package describes the work of a frame as plain data and moves it between isolates. A builder on one isolate makes
a `FramePlan` and a runner on another isolate records it on the GPU. The plan holds no GPU objects. You can check and
compare it without a GPU.

## Frame plans

A `FramePlan` lists the render targets of the frame by name, its GPU buffers by name and its passes in order. A
`RenderPassPlan` has colour and depth attachments and its draws. A `DispatchPlan` is a compute dispatch. A `DrawPlan`
names its vertex and pixel shaders by id and holds its geometry, its raster, depth, blend and stencil state, its
viewport and the resources of each stage. Formats have the form of DXGI names without their prefix, such as
`R11G11B10_FLOAT`. Sampler and blend states follow Direct3D 11.

| Part | Use |
|---|---|
| `FrameRole` | A constant block that a draw binds by its role, such as the camera's block. The plan gives the bytes of each role for the frame in `frameBlocks`. A draw that binds only roles and kept blocks stays the same object from frame to frame. |
| `retained` | A stamp per pass. A runner may leave out a pass that ran with the same stamp on targets that nothing has drawn into since, such as the shadow map of a light while nothing it sees moves. |
| `RowSet` | The kept rows of a pass, drawn before its other draws and culled on the GPU. The codec sends a row again only when its draw changes. |
| `runnerState` | A slot on passes, draws and stage resources for the objects of a runner. It is not part of the plan. |

## Plan codec

`PlanWriter` turns a plan into a `PlanMessage` for `SendPort.send` and `PlanReader` turns the message back into a
plan on the receiving isolate. Byte blocks, samplers, textures and other objects that a runner keys its GPU objects on
cross once and are then referred to by id. The plan that the reader returns therefore shares these objects from
frame to frame, as the builder's plan does. A draw or a pass that the builder keeps for two frames in a row is kept
on both sides. A later message sends only its changes.

The bytes of frame roles change in most frames. Give the writer a `PlanBlockStore` to put them in memory outside the
Dart heap, where the reader reads them in place. The store frees a block once both sides have dropped it and
`PlanWriter.release` reports that the reader has run every plan that could refer to it.

The writer and the reader keep their tables in step without messages for it. Use one writer and one reader for one
stream of plans. Read every message in the order of writing.

## JSON form

`planToJson` writes a plan as JSON and keeps the byte payloads apart as named blobs. `planFromJson` reads it back.
The form carries the format tag `prismarine.frame/1`, or your own tag given as `format`. The reader fails on a plan
with another tag.

## Rows and cooked scenes

`RowLayout` describes a row of a GPU table as typed fields with std430 offsets and generates the matching GLSL
struct. `RowTable` keeps the rows in one byte buffer for a storage buffer and keeps the range of bytes written since
the last upload. `objectRowOf` and `instanceRowOf` build the rows of the objects and of the mesh batches of a scene.
Each row starts with the members of your object or instance block that your shaders read. The fields that the
renderer fills follow, such as an object's light set and a batch's bounding sphere.

`CookedScene` is the data model of a cooked scene as `cooked.json` describes it: its geometry pools, its texture
arrays as KTX2 files and the place of each mesh batch and texture. `pulledDir` finds the cooked directory of some
content. `PRISMARINE_PULLED` gives a directory or `off` for none. `MCSM_PULLED` is read when it is not set.

`ShaderRecord` is the interface of one shader: its constant blocks, textures, samplers, vertex inputs and storage
resources, read from the JSON form of the shader's reflection. `StencilValues` follows the values that a depth target's
stencil can hold from the replacing writes since its clear.

`sameFloat32Bits` and `scratchFloats` compare and read float lists without an allocation per value.

## Kept parts of a builder

A builder that makes a plan every frame keeps what holds from the last frame, so the codec names it by id and the
runner binds what it kept. `DrawKeep` gives last frame's draw or dispatch object again when everything it draws is the
same: its programs, state, viewport, the bytes of its blocks, its textures and samplers. A block whose bytes change
each frame is bound by a frame role of the draw's slot. `keptRowSet` gives a pass's rows as last frame's set while its
ids, plans, bounds and culling values hold.

A skinning batch skins every skinned mesh of a frame in one compute dispatch of your program. `SkinSources` holds each
mesh's source vertices once in one buffer. Its view is a new object whenever it grows, so the codec sends it again.
`SkinGroups` gives each mesh whole 64-thread groups and keeps the bytes view of its table while the count holds.
`SkinDispatch` keeps the dispatch while its group count and its sources hold. Your builder gives the program, the
source bytes and the rows of each mesh.

## Checks

Run `dart test` in `packages/prismarine_frame`. The allocation lint covers the codec and the parts of the plan that a
builder calls each frame.
