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
# can read the release repo, MCSM_ENGINE_REPO (owner/name: the environment, else
# the private config, tools/toolchain/private_env.sh), or
# MCSM_ENGINE_ARCHIVE=<a downloaded .tar.xz>, its .sha256
# beside it), plus tar and xz. MCSM_DATA: the environment, else .env,
# else the repo's data/. The Flutter SDK: $MCSM_FLUTTER, else data/flutter,
# else the `flutter` on PATH. Windows: fetch.ps1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
# setting <key>…: the first value of a key in the private config, the first
# private/config/*.env found walking up from here.
setting() {
  local d=$here f k
  while [[ $d != / ]]; do
    if [[ -d $d/private/config ]]; then
      for f in "$d"/private/config/*.env; do
        [[ -f $f ]] || continue
        for k in "$@"; do
          sed -n "s/^$k=//p" "$f" | tail -1 | sed -e "s/^[\"']//" -e "s/[\"']\$//"
        done
      done | sed -n 1p
      return 0
    fi
    d=$(dirname "$d")
  done
}
dest=${PRISMARINE_ENGINE_DIR:-${MCSM_DATA:+$MCSM_DATA/engine}}
dest=${dest:-$repo_root/data/engine}
flutter_sdk=${PRISMARINE_FLUTTER:-${MCSM_FLUTTER:-}}
if [[ -z $flutter_sdk ]]; then
  command -v flutter >/dev/null || { echo "mcsm: no Flutter SDK: set PRISMARINE_FLUTTER or put flutter on PATH" >&2; exit 1; }
  flutter_sdk=$(cd "$(dirname "$(command -v flutter)")/.." && pwd)
fi
archive=${PRISMARINE_ENGINE_ARCHIVE:-${MCSM_ENGINE_ARCHIVE:-}}
repo=${PRISMARINE_ENGINE_REPO:-${MCSM_ENGINE_REPO:-}}
[[ -n $repo ]] || repo=$(setting PRISMARINE_ENGINE_REPO MCSM_ENGINE_REPO)
if [[ -z $repo && -z $archive ]]; then
  echo "mcsm: missing machine setting MCSM_ENGINE_REPO (the engine release repo, owner/name)" >&2
  exit 1
fi
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
if [[ -n $archive ]]; then
  # A local copy (with its .sha256 beside it) instead of the download.
  cp "$archive" "$tmp/$asset"
  cp "$archive.sha256" "$tmp/$asset.sha256"
else
  echo "mcsm: fetching $asset from $repo release $tag"
  gh release download "$tag" -R "$repo" -p "$asset" -p "$asset.sha256" -D "$tmp"
fi
(cd "$tmp" && sha256 -c "$asset.sha256")
mkdir -p "$dest"
rm -rf "${dest:?}/${target:?}"
xz -dc "$tmp/$asset" | tar -C "$dest" -xf -
outs=()
for out in "$dest/$target"/src/out/*/; do
  out=${out%/}
  ln -sfn "$flutter_sdk/bin/cache/dart-sdk" "$out/dart-sdk"
  outs+=("$(basename "$out")")
done
want=$(sed -n 's/^engine_revision=//p' "$dest/$target/mcsm-engine.txt")
have=$(cat "$flutter_sdk/bin/internal/engine.version" 2>/dev/null || true)
[[ $want == "$have" ]] || echo "mcsm: warning: the engine is for Flutter engine $want, the Flutter SDK has ${have:-unknown}" >&2
echo "mcsm: engine $target in $dest/$target ($(du -sh "$dest/$target" | cut -f1))"
case $target in
  macos-*) echo "mcsm: play.sh and tools/toolchain/env.sh use it from now on (MCSM_LOCAL_ENGINE=off in .env to stop)" ;;
  *) echo "mcsm: build with: flutter build linux --release --local-engine-src-path=$dest/$target/src --local-engine=${outs[0]} --local-engine-host=${outs[0]}" ;;
esac
