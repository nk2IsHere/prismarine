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

## Measured

See `third_party/flutter_engine/README.md` and status-perf ("E").
