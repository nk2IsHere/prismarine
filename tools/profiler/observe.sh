#!/bin/zsh
# observe.sh <outDir> "<name:t0:t1> …" <dart script> [script args…]: runs a
# headless Dart tool (e.g. packages/mcsm_game/tool/route_bench.dart with
# BENCH_FRAMES) under the VM service and profiles it with
# tools/profiler/bin/profile.dart over the given game-time windows (CPU per
# isolate, GC, PROFILE_TRACE allocation sites; for those also set
# OBSERVE_DART_FLAGS=--no-inline-alloc).
#
# The target runs with --no-pause-isolates-on-exit (an observed VM otherwise
# waits at exit for a debugger, forever) in its own process group, which is
# killed on exit, timeout (OBSERVE_TIMEOUT seconds, default 1800), INT or
# TERM, so neither the VM nor its Dart Development Service is left behind.
set -e
out=${1:?outDir}; wins=${2:?windows}; shift 2
script=${1:?script}; shift
source ${0:A:h:h:h}/tools/toolchain/env.sh
mkdir -p $out
export BENCH_FRAMES=${BENCH_FRAMES:-$out/frames.jsonl}
# A previous run's frames would end the windows at once.
rm -f $BENCH_FRAMES
# perl's setpgrp makes the target a process-group leader (macOS has no setsid).
perl -e 'setpgrp(0, 0); exec @ARGV' -- dart ${=OBSERVE_DART_FLAGS} \
  --no-pause-isolates-on-exit run --observe=0 --disable-service-auth-codes \
  $script "$@" > $out/stdout.txt 2>&1 &
pg=$!
watchdog=
cleanup() {
  [[ -n $watchdog ]] && kill $watchdog 2>/dev/null
  kill -TERM -- -$pg 2>/dev/null; sleep 1; kill -KILL -- -$pg 2>/dev/null; true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# The timeout: a loop that also ends within a second of this script.
self=$$
( for i in $(seq 1 ${OBSERVE_TIMEOUT:-1800}); do
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
(cd ${0:A:h} && dart run bin/profile.dart "ws://${uri#http://}ws" $BENCH_FRAMES $out ${=wins})
wait $pg 2>/dev/null || true
