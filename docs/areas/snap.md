# prismarine_snap

The package writes an object graph to a binary stream and reads it back with the same identities. Shared references
and cycles come back as they were. Use it for snapshots of a running simulation, such as the whole state between two
frames.

You register a codec (`SnapCodec`) for each class with state. A codec writes what the constructor of the object needs
where the object is first referenced and writes the rest of its state later. A cycle therefore never runs through a
constructor. Typed lists are written byte for byte, and closures are written by a recipe that you register.

Objects that both sides already have, such as the roots of a fresh session or data loaded from files, are registered on
the writer and the reader in the same order. The stream then holds only their state.

The stream has unsigned integers as LEB128 varints, signed integers in zigzag form, doubles as their 8 little-endian
bytes and every object once, referred to by its index after that.

## Checks

Run `dart test` in `packages/prismarine_snap`.
