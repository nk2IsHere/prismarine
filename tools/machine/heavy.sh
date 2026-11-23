#!/usr/bin/env bash
# heavy.sh <command…> runs a heavy step in one of the heavy-job slots of the
# machine. A build, a real-time run, a reslice and a large test suite are heavy
# steps. The script waits for a free slot and does not start the command while
# measure.sh holds the machine. The command runs at nice 15 and its exit code
# is the exit code of the script.
#
#   PRISMARINE_HEAVY_SLOTS  the number of slots, 2 by default. HEAVY_SLOTS is
#                           read when it is not set.
#   PRISMARINE_HEAVY_FG     1 runs the command at normal priority. HEAVY_FG is
#                           read when it is not set.
#   PRISMARINE_LOCK_POLL    the seconds between two looks at the locks, 5 by
#                           default.
set -u
[[ $# -gt 0 ]] || { echo "usage: heavy.sh <command…>" >&2; exit 2; }
dir=$("$(dirname "${BASH_SOURCE[0]}")/lockdir.sh") || exit 1
slots=${PRISMARINE_HEAVY_SLOTS:-${HEAVY_SLOTS:-2}}
fg=${PRISMARINE_HEAVY_FG:-${HEAVY_FG:-}}
poll=${PRISMARINE_LOCK_POLL:-5}

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

while true; do
  if [[ -d $dir/measure-lock ]]; then
    free_stale "$dir/measure-lock"
    sleep "$poll"
    continue
  fi
  for ((i = 1; i <= slots; i++)); do
    slot=$dir/heavy-slots/slot$i
    if mkdir "$slot" 2>/dev/null; then
      echo "$$ $*" >"$slot/owner"
      trap 'rm -f "$slot/owner"; rmdir "$slot" 2>/dev/null' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      if [[ -n $fg ]]; then "$@"; else nice -n 15 "$@"; fi
      exit $?
    fi
    free_stale "$slot"
  done
  sleep "$poll"
done
