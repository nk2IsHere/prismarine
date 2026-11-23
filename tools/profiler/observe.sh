#!/bin/zsh
# observe.sh <outDir> "<name:t0:t1> …" <dart script> [script args…] runs a
# headless Dart program under the VM service and profiles it with
# bin/profile.dart over the windows of game time. The program writes one line
# per frame with its game time, such as {"t": 12.5}, to the file in
# PRISMARINE_OBSERVE_CLOCK, <outDir>/frames.jsonl by default. It runs with
# --no-pause-isolates-on-exit in a process group of its own, which is killed
# on exit, on INT or TERM and after PRISMARINE_OBSERVE_TIMEOUT seconds, 1800
# by default. PRISMARINE_OBSERVE_DART_FLAGS adds flags of the VM, such as
# --no-inline-alloc for PRISMARINE_PROFILE_TRACE. PRISMARINE_PROFILER_PACKAGES
# gives the package config of profile.dart in a checkout without one. The
# README of the profiler lists the older forms of the variables.
set -e
out=${1:?outDir}; wins=${2:?windows}; shift 2
script=${1:?script}; shift
mkdir -p $out
clock=${PRISMARINE_OBSERVE_CLOCK:-${BENCH_FRAMES:-$out/frames.jsonl}}
export PRISMARINE_OBSERVE_CLOCK=$clock BENCH_FRAMES=$clock
# The frames of an earlier run would end the windows at once.
rm -f $clock
dart_flags=${PRISMARINE_OBSERVE_DART_FLAGS:-$OBSERVE_DART_FLAGS}
timeout=${PRISMARINE_OBSERVE_TIMEOUT:-${OBSERVE_TIMEOUT:-1800}}
# The setpgrp of perl makes the program the leader of a process group. macOS
# has no setsid.
perl -e 'setpgrp(0, 0); exec @ARGV' -- dart ${=dart_flags} \
  run --observe=0 --no-pause-isolates-on-exit --disable-service-auth-codes \
  $script "$@" > $out/stdout.txt 2>&1 &
pg=$!
watchdog=
cleanup() {
  [[ -n $watchdog ]] && kill $watchdog 2>/dev/null
  kill -TERM -- -$pg 2>/dev/null; sleep 1; kill -KILL -- -$pg 2>/dev/null; true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# The timeout is a loop that also ends within a second after this script.
self=$$
( for i in $(seq 1 $timeout); do
    sleep 1; kill -0 $self 2>/dev/null || exit 0
  done
  echo "observe.sh: timeout" >&2; kill -TERM $self ) &
watchdog=$!
for i in $(seq 1 180); do
  uri=$(grep -m1 -o 'http://127.0.0.1:[0-9]*/' $out/stdout.txt 2>/dev/null || true)
  [[ -n $uri ]] && break
  kill -0 $pg 2>/dev/null || break
  sleep 1
done
if [[ -z $uri ]]; then echo "observe.sh: no VM service URI"; exit 1; fi
dart ${PRISMARINE_PROFILER_PACKAGES:+--packages=$PRISMARINE_PROFILER_PACKAGES} \
  ${0:A:h}/bin/profile.dart "ws://${uri#http://}ws" $clock $out ${=wins}
wait $pg 2>/dev/null || true
