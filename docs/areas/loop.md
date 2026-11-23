# prismarine_loop

The package holds parts of a real-time frame loop on Flutter: frame pacing, GC pacing, a frame limiter for Metal, a
memory census, a JSON-lines writer and the focus, cursor and mouse-look state of a desktop window. It is a Flutter
package.

## Frame pacing

`FramePace` steps the game on every n-th display frame, with n from 1 to 4. A display without variable refresh shows
each picture for whole frames. A scene that the machine cannot draw at the full rate then plays evenly at a half, a
third or a quarter of it. Call `begin` at the start of each tick with the time in microseconds. It returns the step in
microseconds, or -1 for a tick that steps nothing. Call `end` after the step with the times of its stages. Once a
second the pace goes down a rate when steps came late or too few of them got a picture. It goes up a rate when every
stage fits the faster rate. A rate that did not hold waits longer before its next try. The `fixed` argument keeps one
divisor for the whole run.

## GC pacing

`GcPacing` keeps the idle notification of the engine away from the Dart VM between frames. Call `beginFrame` when a
frame starts and `endFrame` when its Dart work is done. The Dart performance mode is balanced inside the frame and
latency between frames. GPU memory that waits for finalization brings the idle notification back once it grows by
`budget`. With the patched engine, `idlePoint` runs young collections at the idle point of the frame, `premark` starts
a mark of the old space ahead of a scene switch and `switchHold` compacts the old space while the screen holds the last
picture of a switch. You pass each engine call as a function. A null function leaves the call out on a stock engine.

## Frame limiter on macOS

Impeller writes the vertices and uniforms of each composite into a ring of four arenas and reuses an arena four frames
later without a wait for the GPU. On macOS nothing bounds the frames in flight. A composite can then read the arena of
a later one. `MetalFrameLimiter.create` returns a limiter on macOS and null elsewhere. Call `beginFrame` at the start of
every frame. It commits an empty command buffer on the Metal queue of the engine and waits until the one from two
frames before has completed, for at most 250 ms.

## Memory census and JSON lines

`MemLog` gives each isolate a census line every `PRISMARINE_MEM_LOG` seconds. Its `due` getter is true when a line is
due. `process` gives the resident set of the process followed by the text of the `figures` function that you pass.
`line` adds the name of the isolate and the wall clock in milliseconds.

`JsonLineWriter` writes one JSON object per line into kept bytes and to a file with synchronous writes. A line makes no
string, map or sink buffer. With a `buffer` of 0 each line is written at its end, for a record that must survive a
crash.

## Focus, cursor and mouse look

`WindowFocus` combines the app lifecycle with the key-window state that the runner reports. `OsCursorHider` asks the
runner to hide the OS cursor while the pointer is over the game area and sends only changes, which keeps the hide and
unhide calls of the runner paired. `MouseLook` holds the pointer still while the game hides its cursor and re-centres it
every frame. It turns the summed mouse movement into the cursor of the game in whole device pixels and keeps the
remainder. `holdsPointer` decides when to hold. `MacMouseLookHost.find` connects to the mouse-look class of the macOS
runner. `package:prismarine_loop/objc.dart` gives the calls into the Objective-C runtime, CoreFoundation and IOSurface.

The runner of your app provides the native side. The channel and class are yours to choose. Your app creates the
channels and passes the class to `MacMouseLookHost.find`. View coordinates are Flutter logical points with the origin at
the top left of the view.

| Part | Runner side | Dart side |
|---|---|---|
| Key window | A method channel that invokes `key` with a bool each time the window becomes or stops being the key window and answers `isKey` with a bool. An unattended run reports nothing. | `WindowFocus.keyWindow` |
| Cursor hiding | A method `setHidden` with a bool that hides or shows the OS cursor with `NSCursor` and keeps the hide and unhide calls paired. The cursor shows while the app is inactive. | `OsCursorHider`, with a function that invokes the method |
| Mouse look | An Objective-C class with the class methods `totalX` and `totalY`, the summed `deltaX` and `deltaY` of mouse-move and drag events in points with y down. `holdAtX:y:` warps the pointer to a view point, dissociates it from the mouse and returns true, or returns false without the key window of the active app. `letGoAtX:y:` warps the pointer to a view point and associates it again. The runner lets go itself when its window resigns key or the app resigns active. | `MacMouseLookHost` |

On Windows the engine reports focus with view focus events. Windows and Linux have no mouse-look host.

| Variable | Effect |
|---|---|
| `PRISMARINE_MEM_LOG` | Seconds between two census lines of an isolate. Unset writes no census. |
| `PRISMARINE_GPU_FRAME_GATE` | `off` turns the frame limiter on macOS off. The limiter is on by default. |

Each variable also reads its `MCSM_` form, such as `MCSM_MEM_LOG`, when the `PRISMARINE_` form is not set.

## Checks

Run `flutter test` in `packages/prismarine_loop`. The tests cover frame pacing, GC pacing with fake engine calls, the
line writer, the mouse-look cursor with a fake host, cursor hiding and window focus. The frame limiter and the macOS
host need a running app on macOS.
