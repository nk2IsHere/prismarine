#!/usr/bin/env bash
# lockdir.sh prints the lock directory of this machine and creates it when it
# is missing. Every repository and every agent on a machine shares the one
# directory. It is $PRISMARINE_LOCKS, else ~/.prismarine/locks.
#
# The directory holds these locks, each a directory with an `owner` file of the
# form "<pid> <command>". A lock whose owner process is gone counts as free.
#   heavy-slots/slot<n>  a heavy job in slot n, taken by heavy.sh
#   measure-lock         a timed run, taken by measure.sh
#   gate-lock            a landing gate in progress, taken by the gate scripts
set -eu
dir=${PRISMARINE_LOCKS:-$HOME/.prismarine/locks}
mkdir -p "$dir/heavy-slots"
echo "$dir"
