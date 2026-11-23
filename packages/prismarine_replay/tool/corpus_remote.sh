#!/bin/bash
# corpus_remote.sh runs a command of a game's corpus program on another
# machine over ssh. Run it without arguments for its usage.
usage() {
  cat <<'EOF'
corpus_remote.sh <command> <tree> [args...]

Ships the committed head of <tree> to the remote machine with git archive,
builds the corpus program of the tree there once, runs <command> of it with
[args...] and copies the results back.

  check       runs the check and copies its report back. --expect=<file>
              takes a local file. The exit code is the check's.
  baseline, rebaseline, record, snapshots
              runs the command and copies the runs and the baseline back

The settings are environment variables.

  CORPUS_HOST     the ssh host
  CORPUS_ROOT     the remote folder that holds trees/ and the remote corpus
  CORPUS_DIR      the remote corpus folder, $CORPUS_ROOT/data/corpus by
                  default. The corpus program must use it by default.
  CORPUS_WRAP     a command in $CORPUS_ROOT that runs its argument, a shell
                  command line, in the build container. bash -c by default.
  CORPUS_PACKAGE  the package of the tree that holds tool/corpus.dart
  CORPUS_LOCAL    the local corpus folder that receives the results
  CORPUS_JOBS     the replays at the same time, 16 by default
  CORPUS_SHIP     an optional command line that runs before the tree is
                  shipped, with TREE set to <tree>, such as one that ships
                  the pinned dependencies of the tree
EOF
}
case ${1:-} in '' | help | -h | --help) usage; exit 0 ;; esac
set -euo pipefail
: "${CORPUS_HOST:?set CORPUS_HOST}" "${CORPUS_ROOT:?set CORPUS_ROOT}"
: "${CORPUS_PACKAGE:?set CORPUS_PACKAGE}" "${CORPUS_LOCAL:?set CORPUS_LOCAL}"
R=$CORPUS_ROOT
D=${CORPUS_DIR:-$R/data/corpus}
WRAP=${CORPUS_WRAP:-bash -c}
ssh_() { ssh -o BatchMode=yes "$CORPUS_HOST" "$@"; }

# Ships the committed head of the tree to $R/trees/<name> and builds the
# corpus program there. Prints <name>, the tree's folder and its commit.
ship() {
  local name
  TREE=$1
  name=$(basename "$TREE")-$(git -C "$TREE" rev-parse --short=8 HEAD)
  if [[ -n ${CORPUS_SHIP:-} ]]; then eval "$CORPUS_SHIP" >&2; fi
  if ! ssh_ "test -x $R/trees/$name/bin/bundle/bin/corpus"; then
    git -C "$TREE" archive --format=tar --prefix="$name/" HEAD |
      ssh_ "mkdir -p $R/trees && cd $R/trees && rm -rf $name && tar -xf - 2>/dev/null"
    ssh_ "cd $R && $WRAP 'cd trees/$name && dart pub get >/dev/null && cd $CORPUS_PACKAGE && dart build cli -t tool/corpus.dart -o $R/trees/$name/bin >/dev/null'" >&2
  fi
  echo "$name"
}

# Runs a command of the corpus program of a shipped tree with its compiled
# workers.
run() {
  local name=$1
  shift
  ssh_ "cd $R && $WRAP 'cd trees/$name/$CORPUS_PACKAGE && CORPUS_COMMIT=${name##*-} dart run tool/corpus.dart $* --jobs=${CORPUS_JOBS:-16} --exe=$R/trees/$name/bin/bundle/bin/corpus'"
}

cmd=$1
shift
case "$cmd" in
  check)
    tree=$1
    shift
    name=$(ship "$tree")
    args=()
    for a in "$@"; do
      if [[ $a == --expect=* ]]; then
        scp -q "${a#--expect=}" "$CORPUS_HOST:$D/expect-$name.txt"
        a=--expect=$D/expect-$name.txt
      fi
      args+=("$a")
    done
    out=checks/$name-$(date +%Y%m%d-%H%M%S)
    set +e
    run "$name" check ${args[@]+"${args[@]}"} --out=$D/$out
    code=$?
    set -e
    mkdir -p "$CORPUS_LOCAL/$out"
    rsync -a --exclude='*.fp.gz' "$CORPUS_HOST:$D/$out/" "$CORPUS_LOCAL/$out/"
    echo "report: $CORPUS_LOCAL/$out/report.txt (fingerprints stay on the remote machine: $D/$out)"
    exit $code
    ;;
  baseline | rebaseline | record | snapshots)
    tree=$1
    shift
    name=$(ship "$tree")
    run "$name" "$cmd" "$@"
    rsync -a "$CORPUS_HOST:$D/runs" "$CORPUS_HOST:$D/baseline" "$CORPUS_LOCAL/"
    ;;
  *)
    usage
    exit 2
    ;;
esac
