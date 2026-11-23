# prismarine_scene

The package holds scene assets on Flutter. It is a Flutter package.

`FileAssetBundle` is an asset bundle that reads each key as an absolute file path. Pass it to a loader that reads
textures through an `AssetBundle` after their keys were made absolute. A read runs off the UI thread. A texture that is
not on disk is served as `staticBlackPng`, a 1×1 transparent black PNG. The bundle reports it once through
`FileAssetBundle.onMissing`, which prints the message by default.

`loadPace` lets a long scene load on the UI isolate give a waiting frame its turn. Call
`if (loadPace() case final p?) await p;` between the steps of the load. It returns null while the load has run less
than `loadTurn`, 4 ms, since the last turn. Otherwise it returns a future that completes after a zero timer. A
frame due meanwhile is drawn first. The common case stays synchronous.

## Checks

Run `flutter test` in `packages/prismarine_scene`.
