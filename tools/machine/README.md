# Machine locks

The scripts in `tools/machine/` share one machine between the builds, tests and timed runs of every repository and every
session on it. A heavy step, such as a release build, a real-time run or a large test suite, runs through `heavy.sh`. A
run whose timings you report runs through `measure.sh`. The details are on [the area page](../../docs/areas/machine.md).

## Usage

| Script | Use |
|---|---|
| `heavy.sh <command…>` | Runs the command in one of the heavy-job slots at nice 15. It waits for a free slot and starts nothing while a measurement holds the machine |
| `measure.sh <command…>` | Waits for a landing gate to end, takes the measure lock and waits for the running heavy jobs to end. Then it prints the load and runs the command at normal priority |
| `lockdir.sh` | Prints the lock directory of the machine and creates it |

Each script returns the exit code of its command. `PRISMARINE_LOCKS` moves the lock directory from
`~/.prismarine/locks`. `PRISMARINE_HEAVY_SLOTS` sets the number of heavy-job slots, 2 by default. Every repository on a
machine must use the same lock directory. Keep each `measure.sh` call to about ten minutes. Builds and gates queue
behind it for the whole call.

## Example

A release build of the sample app in a heavy-job slot, from `apps/prismarine_sample`:

    ../../tools/machine/heavy.sh flutter build macos --release

A timed run on a quiet machine:

    tools/machine/measure.sh <your benchmark command>

`tools/machine/test/locks_test.sh` checks the scripts in a few seconds.

## Platforms

The scripts need bash 3.2 or later. They run on macOS and Linux. Windows has no form of them.
