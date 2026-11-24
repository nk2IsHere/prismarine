# prismarine_sample

The sample of prismarine shows Intel's Sponza, the palace atrium with its arches, columns and coloured curtains. A sun
and eight coloured lights move through the hall in a light fog. Their light bounces off the walls, floors and curtains,
and the floors reflect the hall. You fly through it with the mouse and keyboard or with a gamepad. It runs on Metal on
macOS and on Vulkan on Linux and Windows.

## Running

Install the tools and put the `prismarine` command on your `PATH`, as [the build page](../../docs/building.md)
describes. Then run the sample from its folder.

```sh
cd apps/prismarine_sample
prismarine run macos
```

On Linux and Windows the platform is `linux` or `windows`. Without one it is the one of your computer. The first run
fetches the engine, downloads about 2.4 GB of Sponza and prepares it in `~/.prismarine/sample`, or in
`%LOCALAPPDATA%\prismarine\sample` on Windows, which takes a few minutes. The options below follow `--`, as in
`prismarine run -- --gi=high`.

## Controls

- W, A, S and D move, Q and E move down and up, and Shift moves faster.
- Drag with the mouse to turn the view. The mouse wheel sets the speed.
- A gamepad moves with the left stick, turns with the right stick and moves down and up with the triggers.
- Space stops and starts the lights.
- F1 shows the debug panel, with the frame graph and the settings of the lights, the sun, the shadows, the camera and
  each effect, with its GPU time.

## Options

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

## Platforms

The sample runs on macOS with Metal and on Linux with Vulkan; both pass the smoke test and the performance run. It
builds on Windows, but it has not run on a Windows GPU yet.

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

The sample converts the model for the GPU on your computer. It does not distribute the model or its conversion.
