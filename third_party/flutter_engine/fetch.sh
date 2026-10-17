#!/usr/bin/env bash
# fetch.sh [target]: downloads the patched Flutter engine (macOS, Linux) from
# the repo's GitHub release (the tag in ./RELEASE), checks its SHA-256, unpacks
# it to $MCSM_DATA/engine/<target>/ and links its out dir's dart-sdk to the
# Flutter SDK's own (the same Dart). target: macos-arm64, macos-x64,
# linux-x64, linux-arm64 (default: this machine's).
#
# On macOS, tools/toolchain/env.sh then finds it by itself (play.sh builds on
# it; MCSM_LOCAL_ENGINE=off in .env goes back to the stock engine). Elsewhere
# it prints the `flutter build` flags. Needs `gh` logged in to an account that
# can read the repo (or MCSM_ENGINE_ARCHIVE=<a downloaded .tar.xz>, its .sha256
# beside it), plus tar and xz. MCSM_DATA: the environment, else .env,
# else the repo's data/. The Flutter SDK: $MCSM_FLUTTER, else data/flutter,
# else the `flutter` on PATH. Windows: fetch.ps1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
if [[ -z ${MCSM_DATA:-} && -f $repo_root/.env ]]; then
  MCSM_DATA=$(sed -n 's/^MCSM_DATA=//p' "$repo_root/.env" | tail -1)
fi
MCSM_DATA=${MCSM_DATA:-$repo_root/data}
[[ $MCSM_DATA == /* ]] || MCSM_DATA=$repo_root/$MCSM_DATA
if [[ -z ${MCSM_FLUTTER:-} ]]; then
  if [[ -x $repo_root/data/flutter/bin/flutter ]]; then
    MCSM_FLUTTER=$repo_root/data/flutter
  else
    MCSM_FLUTTER=$(cd "$(dirname "$(command -v flutter)")/.." && pwd)
  fi
fi
repo=${MCSM_ENGINE_REPO:-<owner>/<repo>}
tag=$(cat "$here/RELEASE")
target=${1:-}
if [[ -z $target ]]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target=macos-arm64 ;;
    Darwin-x86_64) target=macos-x64 ;;
    Linux-x86_64) target=linux-x64 ;;
    Linux-aarch64|Linux-arm64) target=linux-arm64 ;;
    *) echo "fetch.sh: no engine for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
fi
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
asset=mcsm-engine-$target.tar.xz
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mcsm-engine-fetch.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT
if [[ -n ${MCSM_ENGINE_ARCHIVE:-} ]]; then
  # A local copy (with its .sha256 beside it) instead of the download.
  cp "$MCSM_ENGINE_ARCHIVE" "$tmp/$asset"
  cp "$MCSM_ENGINE_ARCHIVE.sha256" "$tmp/$asset.sha256"
else
  echo "mcsm: fetching $asset from $repo release $tag"
  gh release download "$tag" -R "$repo" -p "$asset" -p "$asset.sha256" -D "$tmp"
fi
(cd "$tmp" && sha256 -c "$asset.sha256")
dest=$MCSM_DATA/engine
mkdir -p "$dest"
rm -rf "${dest:?}/${target:?}"
xz -dc "$tmp/$asset" | tar -C "$dest" -xf -
outs=()
for out in "$dest/$target"/src/out/*/; do
  out=${out%/}
  ln -sfn "$MCSM_FLUTTER/bin/cache/dart-sdk" "$out/dart-sdk"
  outs+=("$(basename "$out")")
done
want=$(sed -n 's/^engine_revision=//p' "$dest/$target/mcsm-engine.txt")
have=$(cat "$MCSM_FLUTTER/bin/internal/engine.version" 2>/dev/null || true)
[[ $want == "$have" ]] || echo "mcsm: warning: the engine is for Flutter engine $want, the Flutter SDK has ${have:-unknown}" >&2
echo "mcsm: engine $target in $dest/$target ($(du -sh "$dest/$target" | cut -f1))"
case $target in
  macos-*) echo "mcsm: play.sh and tools/toolchain/env.sh use it from now on (MCSM_LOCAL_ENGINE=off in .env to stop)" ;;
  *) echo "mcsm: build with: flutter build linux --release --local-engine-src-path=$dest/$target/src --local-engine=${outs[0]} --local-engine-host=${outs[0]}" ;;
esac
