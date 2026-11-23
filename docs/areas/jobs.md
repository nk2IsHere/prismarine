# prismarine_jobs

The package runs work off the frame and sets the priority of threads on macOS, Windows and Linux.

## Job pool

`JobPool` is a bounded pool of one-shot worker isolates. Each job runs in its own `Isolate.run`. Its result returns
through `Isolate.exit` without a copy. Queued jobs start by priority, then in order. A job takes a cancellation token,
and the pool keeps counts of started, finished and failed jobs.

## Thread roles

A thread has one of two roles. The frame role is for the work that a frame waits for, such as the simulation tick or
the build of a frame plan. The background role is for loads and other work that a frame does not wait for.

| OS | Frame role | Background role |
|---|---|---|
| macOS | User-interactive QoS | Utility QoS |
| Windows | Above normal priority, out of EcoQoS | Below normal priority, in EcoQoS |
| Linux | A 1 ms EEVDF slice (kernel 6.12 on), the highest best-effort I/O level and a nice 5 above the process where `RLIMIT_NICE` allows it | A nice 10 below the process and the lowest best-effort I/O level, or `SCHED_BATCH` for a thread that could not raise its nice again |

None of these needs privileges. A process that runs at a raised nice keeps its threads as they are. Before kernel 6.12
the role tries the slice once per isolate and then uses the nice and I/O calls.

## Memory room

`MemoryRoom` answers whether the machine has memory to spare for reads far ahead of their use. A read made minutes
early holds its parsed data that long. A machine short of memory pays for it in paging. The answer comes from the
memory readings of the OS at most once a second: the memory pressure level and swap growth on macOS, available memory
and the cgroup limit on Linux and the commit limit on Windows. A budget for the process applies as well.

| Variable | Effect |
|---|---|
| `PRISMARINE_AHEAD_BUDGET_MB` | The footprint of the process past which nothing is read far ahead. The default is 40 % of the memory of the machine. |
| `PRISMARINE_AHEAD_FREE_MB` | The available memory that reads far ahead need. The default is 2048. |
| `PRISMARINE_AHEAD` | `deep` or `short` fixes the answer for A/B runs. |

Each variable also reads its `MCSM_` form, such as `MCSM_AHEAD_FREE_MB`, when the `PRISMARINE_` form is not set.

## Checks

Run `dart test` in `packages/prismarine_jobs`. The tests check the logic of the thread roles for each OS with fake
system calls on any host.
