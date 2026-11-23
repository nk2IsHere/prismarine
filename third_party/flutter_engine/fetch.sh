#!/usr/bin/env bash
# fetch.sh [target] downloads the patched Flutter engine for macOS or Linux from
# the GitHub release that RELEASE gives, checks its SHA-256 and unpacks it to
# <engine dir>/<target>/. It links the dart-sdk of each out dir to the one of
# the Flutter SDK, which has the same Dart. The targets are macos-arm64,
# macos-x64, linux-x64 and linux-arm64. The default is the target of this
# machine. Windows uses fetch.ps1.
#
# The settings below are also read in their MCSM_ form.
#   PRISMARINE_ENGINE_DIR      the engine directory, by default
#                              $MCSM_DATA/engine when MCSM_DATA is set, else
#                              ~/.prismarine/engine, the one of the toolchain
#   PRISMARINE_FLUTTER         the Flutter SDK, by default the flutter on PATH
#   PRISMARINE_ENGINE_REPO     owner/name of the release repository, by default
#                              its value in a private/config/*.env above this
#                              directory. MCSM_ENGINE_REPO is the last fallback.
#   PRISMARINE_ENGINE_ARCHIVE  a downloaded archive with its .sha256 beside it,
#                              unpacked in place of the download
# The download needs gh, logged in to an account that can read the repository.
# The unpacking needs tar and xz.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# setting <key> prints the value of the key in the nearest private/config/*.env
# above this directory that has it.
setting() {
  local d=$here f v
  while [[ $d != / ]]; do
    if [[ -d $d/private/config ]]; then
      for f in "$d"/private/config/*.env; do
        [[ -f $f ]] || continue
        v=$(sed -n "s/^$1=//p" "$f" | tail -1 | sed -e "s/^[\"']//" -e "s/[\"']\$//")
        [[ -n $v ]] && { echo "$v"; return 0; }
      done
    fi
    d=$(dirname "$d")
  done
}
dest=${PRISMARINE_ENGINE_DIR:-${MCSM_DATA:+$MCSM_DATA/engine}}
dest=${dest:-$HOME/.prismarine/engine}
flutter_sdk=${PRISMARINE_FLUTTER:-${MCSM_FLUTTER:-}}
if [[ -z $flutter_sdk ]]; then
  command -v flutter >/dev/null || { echo "fetch.sh: no Flutter SDK. Set PRISMARINE_FLUTTER or put flutter on PATH." >&2; exit 1; }
  flutter_sdk=$(cd "$(dirname "$(command -v flutter)")/.." && pwd)
fi
archive=${PRISMARINE_ENGINE_ARCHIVE:-${MCSM_ENGINE_ARCHIVE:-}}
repo=${PRISMARINE_ENGINE_REPO:-}
[[ -n $repo ]] || repo=$(setting PRISMARINE_ENGINE_REPO)
[[ -n $repo ]] || repo=${MCSM_ENGINE_REPO:-}
[[ -n $repo ]] || repo=$(setting MCSM_ENGINE_REPO)
if [[ -z $repo && -z $archive ]]; then
  echo "fetch.sh: no release repository. Set PRISMARINE_ENGINE_REPO to owner/name, or PRISMARINE_ENGINE_ARCHIVE to a downloaded archive." >&2
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
asset=prismarine-engine-$target.tar.xz
tmp=$(mktemp -d "${TMPDIR:-/tmp}/prismarine-engine-fetch.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT
if [[ -n $archive ]]; then
  # A local copy (with its .sha256 beside it) instead of the download.
  cp "$archive" "$tmp/$asset"
  cp "$archive.sha256" "$tmp/$asset.sha256"
else
  echo "fetch.sh: fetching $asset from $repo release $tag"
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
info=$dest/$target/prismarine-engine.txt
[[ -f $info ]] || info=$dest/$target/mcsm-engine.txt
want=$(sed -n 's/^engine_revision=//p' "$info")
have=$(cat "$flutter_sdk/bin/internal/engine.version" 2>/dev/null || true)
[[ $want == "$have" ]] || echo "fetch.sh: warning: the engine is for Flutter engine $want and the Flutter SDK has ${have:-an unknown one}" >&2
echo "fetch.sh: engine $target in $dest/$target ($(du -sh "$dest/$target" | cut -f1))"
case $target in
  macos-*) os=macos ;;
  *) os=linux ;;
esac
echo "fetch.sh: build with: flutter build $os --release --local-engine-src-path=$dest/$target/src --local-engine=${outs[0]} --local-engine-host=${outs[0]}"
