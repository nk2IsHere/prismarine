# prismarine_pad

The package reads the game pads of the host through the gamepad subsystem of SDL3. SDL is built from source and linked
into a small Rust library, and players need no SDL installed. Every pad counts as an Xbox pad, by button position.

SDL runs on a thread of its own, which polls every few milliseconds and publishes a snapshot. Your app reads the pad
in use once a frame with `HostPads.read` and turns the reading into its own pad state. `HostPads.devices` lists the
connected pads, and `HostPads.chosen` picks one of them.

Building SDL needs CMake and a C compiler on every OS.

## Checks

- `dart test` in `packages/prismarine_pad`.
- `cargo test` in `packages/prismarine_pad/native` starts the real SDL with virtual pads.
- `cargo run --release --example pad_probe` in the same directory prints what a real pad gives.
- `cargo clippy --all-targets` denies an undocumented `unsafe` block.
