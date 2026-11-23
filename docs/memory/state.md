---
name: state
description: The current state of prismarine on one page, rewritten by every merge that changes it
type: project
---

# State

The decisions are in [decisions](decisions.md). The design of the split is in
[the split design](../specs/2026-11-23-prismarine-split-design.md).

Migration steps 1 to 3 are done. The workspace, the lints with their config, the sample app and the gate in the
private repo are in place. The packages are `prismarine_kept`, `prismarine_snap`, `prismarine_math`,
`prismarine_jobs`, `prismarine_cargo` and `prismarine_pad`, each with a page in `docs/areas/`. mcsm pins prismarine
by commit and uses these packages. mcsm runs the lints from its pinned checkout with its own config. The heavy-job and
measure locks of each machine are the scripts in `tools/machine/`, which both repositories use.
