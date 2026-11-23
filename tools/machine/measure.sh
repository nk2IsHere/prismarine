#!/usr/bin/env bash
# measure.sh <command…> runs a timed run on a quiet machine. It waits while a
# landing gate is in progress, takes the measure lock of the machine and waits
# for the running heavy jobs to end. heavy.sh starts no new job while the lock
# is held. The command runs at normal priority after a line with the load of
# the machine. Its exit code is the exit code of the script.
#
# Keep each call short, about ten minutes at most. Queued builds and gates wait
# for the whole call.
#
#   PRISMARINE_LOCK_POLL  the seconds between two looks at the locks, 5 by
#                         default.
set -u
[[ $# -gt 0 ]] || { echo "usage: measure.sh <command…>" >&2; exit 2; }
dir=$("$(dirname "${BASH_SOURCE[0]}")/lockdir.sh") || exit 1
poll=${PRISMARINE_LOCK_POLL:-5}
lock=$dir/measure-lock

# Frees the lock directory $1 when its owner process has ended.
free_stale() {
  local owner
  owner=$(cut -d' ' -f1 "$1/owner" 2>/dev/null)
  if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -f "$1/owner"
    rmdir "$1" 2>/dev/null
  fi
  return 0
}

while [[ -d $dir/gate-lock ]]; do
  free_stale "$dir/gate-lock"
  [[ -d $dir/gate-lock ]] && sleep "$poll"
done
until mkdir "$lock" 2>/dev/null; do
  free_stale "$lock"
  sleep "$poll"
done
echo "$$ $*" >"$lock/owner"
trap 'rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for slot in "$dir"/heavy-slots/*; do
  while [[ -d $slot ]]; do
    free_stale "$slot"
    [[ -d $slot ]] && sleep "$poll"
  done
done
if [[ -r /proc/loadavg ]]; then
  load=$(cut -d' ' -f1-3 /proc/loadavg)
else
  load=$(sysctl -n vm.loadavg 2>/dev/null || uptime)
fi
echo "measure.sh: load $load" >&2
"$@"
