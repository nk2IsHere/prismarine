# Machine locks

The scripts in `tools/machine/` share one machine between the agents and the sessions of every repository on it. A
heavy step, such as a release build, a real-time run or a large test suite, runs through `heavy.sh`. A run whose
timings you report runs through `measure.sh`.

| Script | Use |
|---|---|
| `heavy.sh <command…>` | Runs the command in one of the heavy-job slots at nice 15. It waits for a free slot and starts nothing while a measurement holds the machine |
| `measure.sh <command…>` | Waits for a landing gate to end, takes the measure lock and waits for the running heavy jobs to end. Then it prints the load and runs the command at normal priority |
| `lockdir.sh` | Prints the lock directory of the machine and creates it |

| Variable | Effect |
|---|---|
| `PRISMARINE_LOCKS` | The lock directory. The default is `~/.prismarine/locks` |
| `PRISMARINE_HEAVY_SLOTS` | The number of heavy-job slots, 2 by default. `HEAVY_SLOTS` is read when it is not set |
| `PRISMARINE_HEAVY_FG` | 1 runs a heavy job at normal priority. `HEAVY_FG` is read when it is not set |
| `PRISMARINE_LOCK_POLL` | The seconds between two looks at the locks, 5 by default |

Keep each `measure.sh` call to about ten minutes. Builds and gates queue behind it for the whole call. Split a long
sweep into one call per case.

## Locks

Each lock is a directory with an `owner` file of the form `<pid> <command>`, made with `mkdir`. The heavy-job slots are
`heavy-slots/slot1` and up, the measurement is `measure-lock` and a landing gate in progress is `gate-lock`. A gate
script takes `gate-lock` itself in the directory that `lockdir.sh` prints. A lock whose owner process has ended counts
as free and the next script that looks at it removes it.

Every repository on a machine must use the same directory. A machine that had its locks in another directory before
gets a symbolic link from `~/.prismarine/locks` to that directory. Scripts of the old layout and these scripts then
see the same locks.

## Platforms

The scripts need bash 3.2 or later. They run on macOS and Linux.

## Checks

Run `tools/machine/test/locks_test.sh`. It takes a few seconds.
