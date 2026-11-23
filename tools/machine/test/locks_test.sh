#!/usr/bin/env bash
# Tests heavy.sh and measure.sh against a lock directory of their own. The locks
# that a test holds by hand have the layout and the owner files that lockdir.sh
# describes. Prints "ok" per test and exits 1 at the first failure.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
export PRISMARINE_LOCKS=$tmp/locks PRISMARINE_LOCK_POLL=0.1
unset PRISMARINE_HEAVY_SLOTS HEAVY_SLOTS PRISMARINE_HEAVY_FG HEAVY_FG
holders=()
cleanup() {
  for p in "${holders[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Starts a process that holds the lock directory $1 until it is killed. Sets
# held to its pid.
hold() {
  mkdir -p "$1"
  sleep 60 >/dev/null 2>&1 &
  held=$!
  echo "$held sleep 60" >"$1/owner"
  holders+=("$held")
}

# Waits up to 5 seconds for the file $1.
wait_for() {
  for _ in $(seq 50); do
    [[ -e $1 ]] && return 0
    sleep 0.1
  done
  return 1
}

# Fails unless the file $1 is still missing after half a second.
still_missing() {
  sleep 0.5
  [[ ! -e $1 ]] || fail "$2"
}

locks=$("$here/lockdir.sh")
[[ $locks == "$PRISMARINE_LOCKS" && -d $locks/heavy-slots ]] || fail "lockdir.sh prints and creates the directory"
echo "ok lockdir"

"$here/heavy.sh" sh -c 'exit 3'
[[ $? == 3 ]] || fail "heavy.sh returns the exit code of the command"
[[ -z $(ls "$locks/heavy-slots") ]] || fail "heavy.sh frees its slot"
echo "ok heavy exit code and slot"

PRISMARINE_HEAVY_SLOTS=1
export PRISMARINE_HEAVY_SLOTS
hold "$locks/heavy-slots/slot1"
h=$held
"$here/heavy.sh" touch "$tmp/ran1" &
still_missing "$tmp/ran1" "heavy.sh waits for a slot held by a live process"
kill "$h"
wait "$h" 2>/dev/null
wait_for "$tmp/ran1" || fail "heavy.sh takes the slot of an ended process"
wait
echo "ok heavy waits for a held slot"

mkdir -p "$locks/heavy-slots/slot1"
echo "999999 gone" >"$locks/heavy-slots/slot1/owner"
"$here/heavy.sh" touch "$tmp/ran2"
[[ -e $tmp/ran2 ]] || fail "heavy.sh frees a slot whose owner does not exist"
echo "ok heavy frees a stale slot"
unset PRISMARINE_HEAVY_SLOTS

hold "$locks/measure-lock"
m=$held
"$here/heavy.sh" touch "$tmp/ran3" &
still_missing "$tmp/ran3" "heavy.sh waits while the measure lock is held"
kill "$m"
wait "$m" 2>/dev/null
wait_for "$tmp/ran3" || fail "heavy.sh starts once the measure lock is free"
wait
echo "ok heavy waits for measure"

hold "$locks/heavy-slots/slot2"
h=$held
"$here/measure.sh" touch "$tmp/ran4" 2>/dev/null &
still_missing "$tmp/ran4" "measure.sh waits for a running heavy job"
[[ -d $locks/measure-lock ]] || fail "measure.sh holds its lock while it waits for heavy jobs"
kill "$h"
wait "$h" 2>/dev/null
wait_for "$tmp/ran4" || fail "measure.sh runs once the heavy jobs ended"
wait
[[ ! -e $locks/measure-lock ]] || fail "measure.sh frees its lock"
echo "ok measure waits for heavy jobs"

hold "$locks/gate-lock"
g=$held
"$here/measure.sh" touch "$tmp/ran5" 2>/dev/null &
still_missing "$tmp/ran5" "measure.sh waits for a landing gate"
[[ ! -e $locks/measure-lock ]] || fail "measure.sh takes no lock while a gate runs"
kill "$g"
wait "$g" 2>/dev/null
wait_for "$tmp/ran5" || fail "measure.sh runs once the gate ended"
wait
echo "ok measure waits for a gate"

out=$("$here/measure.sh" sh -c 'exit 4' 2>&1)
[[ $? == 4 ]] || fail "measure.sh returns the exit code of the command"
[[ $out == "measure.sh: load "* ]] || fail "measure.sh prints the load"
echo "ok measure exit code and load"
