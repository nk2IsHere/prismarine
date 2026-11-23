---
name: state
description: The current state of prismarine on one page, rewritten by every merge that changes it
type: project
---

# State

The decisions are in [decisions](decisions.md). The design of the split is in
[the split design](../specs/2026-11-23-prismarine-split-design.md).

Migration steps 1 and 2 are done. The workspace, the lints with their config, the sample app and the gate in the
private repo are in place. The packages are `prismarine_kept`, `prismarine_snap`, `prismarine_math`,
`prismarine_jobs`, `prismarine_cargo` and `prismarine_pad`, each with a page in `docs/areas/`. mcsm pins prismarine
by commit and uses these packages. Step 3 is next, with mcsm running the lints from its pinned checkout and the machine
scripts in `tools/machine/`.
