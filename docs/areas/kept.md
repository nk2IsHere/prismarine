# prismarine_kept

`KeptMap`, `KeptSet` and `KeptList` are collections that keep their storage when you clear them. The maps and sets of
the Dart VM free their storage on `clear()`, and refilling them in the next frame allocates again. Use a kept
collection for state that a frame clears and fills again, such as the set of objects drawn in this frame.

A kept map or set compares keys by `==` and `hashCode`, or by identity with its `identity` constructor. Iteration
follows the order of insertion, and a change during iteration throws, as with the default map.

## Checks

Run `dart test` in `packages/prismarine_kept`.
