# prismarine_sample

The sample of prismarine shows Intel's Sponza, the palace atrium with its arches, columns and coloured curtains. A sun
with a shadow map and eight coloured point lights that move through the hall light it. You fly through it with the
mouse and keyboard or with a gamepad. [prismarine_pbr](../../docs/areas/pbr.md) builds the frames and
[prismarine_render](../../docs/areas/render.md) records them on Flutter GPU, on Metal on macOS and on Vulkan on Linux
and Windows. The same app is the smoke test of the gate and a performance scene.

## The model

The model is not part of the repository. `tool/fetch.dart` downloads it from Intel into `data/sample` of the
repository, or into the directory in `PRISMARINE_SAMPLE_DATA`, and prepares it for the GPU with `prepareGltf` of
[prismarine_assets](../../docs/areas/assets.md). The script reads only the glTF part of each archive.

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

## Building

The app needs the patched engine. `tool/shaders.sh` builds the shaders of prismarine_pbr with the impellerc of the
engine into `shaders_generated/`, which the build carries as assets. Then build for your platform with the flags of
the engine, as [the engine page](../../docs/areas/engine.md) describes.

```
tool/shaders.sh <engine>/out/<build>/impellerc
flutter build macos --release --local-engine-src-path=<engine> \
  --local-engine=<build> --local-engine-host=<build>
```

## Running

The app starts at the first camera of the scene. W, A, S and D move, Q and E move down and up, Shift moves faster, a
mouse drag turns the view and the wheel sets the speed. A gamepad moves with the left stick, turns with the right
stick and moves down and up with the triggers. Space stops and starts the lights. F1 shows the debug panel with the
frame graph and the settings of the lights and their markers, the sun, the shadow map with a view of it and the
camera.

| Option | Effect |
|---|---|
| `--data=<dir>` | The data directory. The default is `PRISMARINE_SAMPLE_DATA`, else `data/sample` of the repository. |
| `--smoke` | Renders a frame from each camera of the scene at 1280 by 720 and compares it with the reference in `smoke/<os>` of the data directory. A frame passes with the same hash, or with at most 0.1 % of its pixels more than 2 levels away. Prints one `SMOKE` line per frame and exits with 0 when every frame passed. |
| `--record` | With `--smoke`, writes the frames as the new references. |
| `--perf=<seconds>` | Flies a fixed path at 1920 by 1080 and writes the frame times into `--out`. Prints a `PERF` line with the frame interval, the build, record and GPU times. |
| `--shot=<png>` | Lays the view out at 1600 by 900 points and writes a picture of it after `--shot-after=<seconds>`, 8 by default. `--panel` opens the panel. |
| `--shadow-view` | Shows the shadow map in the top left corner from the start. |
| `--no-shadows` | Starts with the sun's shadows off. |
| `--sun=<elevation>,<azimuth>` | The direction of the sun in degrees. The default is the scene's directional light when its intensity is above 0, else a high sun. |
| `--background` | A small window that does not take focus, for unattended runs. |

At 1920 by 1080 the scene holds 120 Hz on a Mac with an Apple GPU, with about 6.1 ms on the GPU, and 60 Hz on Linux
with an RTX 4060 Ti, with about 5.4 ms on the GPU. A frame has 904 draws and records the shadow pass only when the sun
moves.

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
