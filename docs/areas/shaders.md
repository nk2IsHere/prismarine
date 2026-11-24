# prismarine_shaders

The package builds the shader bundles of a game ahead of time with impellerc, the shader compiler of the Flutter
engine. It needs the impellerc of the patched engine, which accepts large uniform blocks, storage resources and a
list of backends for each entry. You use it as a Dart library or through its command line.

## Program trees

A program tree has a folder for each effect under `programs/`, such as `programs/Mesh/` with `skinned.vert` and
`lit.frag`. Every file is one bundle entry with the id `<effect>/<file>` and its extension gives its stage. A
`bodies` folder holds the files that programs include and gives no entries. `buildShaderBundles` builds each effect
in shards of 25 entries by default and writes one gzip-compressed bundle for each backend, such as
`bundle/vulkan/Mesh.0.shaderbundle.gz`. The sources of a shard then move to `programs/Mesh/0/`, where they stay
editable next to their bundle. A shard that fails is built again entry by entry. `build.log` lists the entries
that failed.

`ShaderBundleSettings` maps each backend to its output folder. Its extra impellerc arguments, such as
`--metal-version=2.3`, go to every impellerc run. Its options, such as `metal_preserve_invariance`, go into every
entry. On macOS each Metal entry also carries a Metal library compiled from its source by the Metal compiler of Xcode. The engine then loads the
library and compiles no shader at run time. A uniform block that the compiler drops becomes a plain struct in the
source. The source then declares the same bindings as the compiled shader.

`keepShaderBundleBackends` copies a bundle with only some of its backends. `decodeShaderBundle` reads a bundle as
nested lists for checks.

## Shader interfaces

`programRecords` returns the interface of every program of a program tree by its id, read from its source with its
includes in place and its `#ifdef` blocks resolved. The [cook](cook.md) writes it as `records.json`.

`shaderInterface` reads the interface of a GLSL source from its declarations, in the JSON form that `ShaderRecord` of
[prismarine_frame](frame.md) reads. A uniform block has the form `uniform Frame { … } cb0;` and its rows are its
std140 size. A texture has the form `uniform texture2D baseColor; // t0` with a separate `uniform sampler s0;`, or
`uniform samplerShadow s4;` for a comparison sampler, and the line `#define baseColor_S s0` pairs them. A vertex input
has the form `layout(location = 0) in vec3 vsi0_POSITION0;`, with its register, semantic and index in its name.
`std140Rows` gives the rows of a block's members.

## Shard cache

With a cache folder, a shard whose sources, includes, settings and tools have not changed is copied from the cache
and not compiled again. A new impellerc or a new Xcode compiles every shard once. You choose the folder. A folder
shared by several builds on one machine saves the most time.

## Command line

`dart run prismarine_shaders bundle <root>` builds the tree in `<root>`. `--help` lists the options.

| Option | Effect |
|---|---|
| `--impellerc` | The impellerc to run. The default is `PRISMARINE_IMPELLERC`, else `MCSM_IMPELLERC`. |
| `--backend` | A backend and its output folder, such as `vulkan=vulkan`. The default is Metal and Vulkan. |
| `--impellerc-arg` | An extra argument for every impellerc run. |
| `--option` | An entry option and its value, such as `spirv_optimize=true`. |
| `--jobs` | The impellerc runs at a time. The default is 4. |
| `--shard` | The entries in a shard. The default is 25. |
| `--cache` | The folder of the shard cache. The default is no cache. |
| `--effects` | Builds only the shards of these effects again and keeps the other bundles. |

## Checks

Run `dart test` in `packages/prismarine_shaders`. The tests that run impellerc need `PRISMARINE_IMPELLERC`. The
test of the Metal compile runs on macOS only.
