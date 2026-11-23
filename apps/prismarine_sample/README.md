# prismarine_sample

The sample of prismarine shows Intel's Sponza, the palace atrium with its arches, columns and coloured curtains. A sun
with a shadow map and eight coloured point lights that move through the hall light it, two of them with shadows, in a
light fog. The light of the sun, the lights and a procedural sky bounces off the walls, floors and curtains through
irradiance probes, with ambient occlusion and reflections. TAA, auto exposure, bloom and the AgX tone map finish the
frame. The app builds the voxel copy of the scene for the probes in about two seconds while it loads. The paths of
the lights keep them away from its walls and columns. You fly through it with the
mouse and keyboard or with a gamepad. [prismarine_pbr](../../docs/areas/pbr.md) builds the frames and
[prismarine_render](../../docs/areas/render.md) records them on Flutter GPU, on Metal on macOS and on Vulkan on Linux
and Windows. The same app is the smoke test of the gate and a performance scene.

## Usage

The app is a Flutter desktop app with runners for macOS, Linux and Windows that turn on Impeller and Flutter GPU. It
needs the patched engine and the model.

### The model

The model is not part of the repository. `tool/fetch.dart` downloads it from Intel into the data directory and
prepares it for the GPU with `prepareGltf` of [prismarine_assets](../../docs/areas/assets.md). The script reads only
the glTF part of each archive. The data directory is the one in `--out=<dir>` of the script or `--data=<dir>` of the
app, else the one in `PRISMARINE_SAMPLE_DATA`, else `~/.prismarine/sample`, or `%LOCALAPPDATA%\prismarine\sample` on
Windows. The app and the script use the same default. An app without a prepared scene shows the fetch command.

| Package | Download | Prepared | Default |
|---|---|---|---|
| Sponza base scene | 2.12 GB | 0.5 GB | yes |
| Colorful curtains | 0.24 GB | 0.1 GB | yes, `--no-curtains` leaves them out |
| Ivy | 0.14 GB | | no, `--ivy` adds it |

```
cd apps/prismarine_sample
dart tool/fetch.dart [--ivy] [--texture-size=1024] [--keep-source]
```

The prepare step takes about a minute. Textures are scaled to 1024 texels by default. `--texture-size=2048` gives
more detail for about four times the memory.

### Building

`tool/shaders.sh` builds the shaders of prismarine_pbr with the impellerc of the engine into `shaders_generated/`,
which the build carries as assets. Then build the app in release mode with the flags of the patched engine, which
`fetch.sh` prints after it fetched the engine. The [root README](../../README.md#building) has the steps for each
platform.

### Running

The app starts at the first camera of the scene. W, A, S and D move, Q and E move down and up, Shift moves faster, a
mouse drag turns the view and the wheel sets the speed. A gamepad moves with the left stick, turns with the right
stick and moves down and up with the triggers. Space stops and starts the lights. F1 shows the debug panel with the
frame graph and the settings of the lights and their markers, the sun, the shadow maps with a view of them, the camera
and each effect of the renderer. While the panel shows, the frame graph splits the GPU time into the parts of the
frame and the title of each effect gives its GPU time.

| Option | Effect |
|---|---|
| `--data=<dir>` | The data directory. The default is `PRISMARINE_SAMPLE_DATA`, else `~/.prismarine/sample`, or `%LOCALAPPDATA%\prismarine\sample` on Windows. |
| `--smoke` | Renders 24 frames from each camera of the scene at 1280 by 720, after a reset of the temporal passes and compares the last with the reference in `smoke/<os>` of the data directory. A frame passes with the same hash, or with at most 0.1 % of its pixels more than 2 levels away. Prints one `SMOKE` line per frame and exits with 0 when every frame passed. |
| `--record` | With `--smoke`, writes the frames as the new references. |
| `--perf=<seconds>` | Flies a fixed path at 1920 by 1080 and writes the frame times into `--out`. Prints a `PERF` line with the frame interval, the build, record and GPU times. |
| `--shot=<png>` | Lays the view out at 1600 by 900 points and writes a picture of it after `--shot-after=<seconds>`, 8 by default. `--panel` opens the panel. |
| `--shadow-view` | Shows the shadow map in the top left corner from the start. |
| `--no-shadows` | Starts with the sun's shadows off. |
| `--sun=<elevation>,<azimuth>` | The direction of the sun in degrees. The default is the scene's directional light when its intensity is above 0, else a high sun. |
| `--background` | A small window that does not take focus, for unattended runs. |
| `--timed` | Splits the frames of `--perf` into timed parts and prints the GPU time of each part. |
| `--taa=<q>` | `off`, `low`, `medium` or `high`. Medium by default. |
| `--bloom=<q>` | `off`, `low`, `medium` or `high`. Medium by default. |
| `--exposure=<e>` | `auto`, or a fixed factor such as `1.5`. Auto by default. |
| `--ev=<ev>` | The compensation of auto exposure in EV, -0.5 by default. |
| `--tonemap=<t>` | `agx`, `aces`, `acesFit` or `neutral`. AgX by default. |
| `--point-shadows=<n>[,<q>]` | The point lights that cast shadows and their quality, such as `4,high`. 2 at medium by default. |
| `--fog=<q>` | `off`, `low`, `medium` or `high`. Medium by default. |
| `--fog-density=<d>`, `--fog-anisotropy=<g>` | The extinction of the fog per metre, 0.006 by default and its forward scattering, 0.5. |
| `--gi=<q>` | The indirect light, `off`, `low`, `medium` or `high`. Medium by default. Off lights the scene with flat sky and ground colours. |
| `--gi-off=<parts>` | Switches off parts of the indirect light, of `sky`, `probes`, `ao` and `ssr`, such as `ao,ssr`. |
| `--gi-view=<view>` | Shows one part of the indirect light, `diffuse`, `occlusion`, `reflections` or `probes`. |
| `--lights=<n>` | The number of point lights of the smoke frames, 8 by default. |

At 1920 by 1080 with the default effects a Mac with an M2 Pro needs about 12 ms on the GPU and shows most frames at
120 Hz, with a p95 interval of about 10 ms. The indirect light costs about 1.5 to 2 ms of it and each of the two
shadowed point lights about 1.7 ms. Without the point shadows the Mac needs about 8.4 ms. On Linux with an RTX 4060 Ti
the indirect light cost about 1 ms over 4.9 ms before the point shadows and the post effects joined. A frame has about
930 draws and about 780 more for the two shadowed point lights. It records the shadow pass of the sun only when the
sun moves and the pass of the point shadows only when the lights move. The costs of the effects are on
[the pbr page](../../docs/areas/pbr.md#costs).

## Example

A release build on an Apple silicon Mac and the smoke test, with the engine fetched into `$PRISMARINE_ENGINE_DIR` and
the model fetched as above:

    cd apps/prismarine_sample
    flutter pub get
    E=$PRISMARINE_ENGINE_DIR/macos-arm64/src
    tool/shaders.sh $E/out/host_release_arm64/impellerc
    flutter build macos --release --local-engine-src-path=$E \
      --local-engine=host_release_arm64 --local-engine-host=host_release_arm64
    B=build/macos/Build/Products/Release/prismarine_sample.app/Contents/MacOS/prismarine_sample
    $B --background --smoke --record
    $B --background --smoke

The code of the app is in [`lib/`](lib/main.dart) and its tools in [`tool/`](tool/fetch.dart).

## Platforms

The app runs on macOS with Metal and on Linux with Vulkan. Both are checked with the smoke test and the performance
run. The Windows build stops in the build of SDL for prismarine_pad, whose file paths are longer than MSBuild accepts.

## Credits

Intel Sponza is from the [Intel Graphics Research samples](https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-research/samples.html).
The page states "Downloads are available under the Creative Commons Attribution license." The `credits_license.txt`
file of each package gives the credits below, then the text of the
[Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/). The app
shows the credits of each package that it loads.

```
Sponza 2022 Scene commissioned by Frank Meinl, sponsored by Anton Kaplanyan.

For personal use and educational use. Limited commercial use for marketing and print purposes.
Contact us at [sponza _dot_ feedback AT intel _dot_ com] to report any issues or feedback. 

If these scenes are used in a publication, please include a citation using the following BibTeX template:

@misc{sponza22,
Author = {Frank Meinl and Anton Kaplanyan},
Year = {2022},
Note = {https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-processing-research/samples.html},
Title = {Intel Sample Library}
} 

If add-ons are used, please also reference the Sponza Addon Package Crew:
Katica Putica
Cristiano Siqueira
Timothy Heath
Justin Prazen
Sebastian Herholz
Bruce Cherniak
Anton Kaplanyan


Additional credit for reference photos
Katica Putica
Princino.photo
Dubrovnik, Croatia
www.princinophoto.com
```

The sample changes the model for the GPU. The geometry is split into parts with 16-bit indices and the textures are
scaled down and stored as KTX2 with mip levels. None of it is distributed.
