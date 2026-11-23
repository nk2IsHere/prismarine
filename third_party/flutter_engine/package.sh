#!/bin/bash
# package.sh <engine/src> <out name> <target> <dest dir> [<host out name>]:
# packs what a release `flutter build … --local-engine` reads from a built
# out dir into <dest>/mcsm-engine-<target>.tar.xz (+ .sha256):
#   <target>/src/out/<out name>/  the engine library or framework, gen_snapshot,
#     icudtl, the patched SDK (+ the flutter_patched_sdk_product link),
#     sky_engine, const_finder, font-subset, impellerc, the desktop headers and
#     C++ client wrapper;
#   <target>/mcsm-engine.txt  what it is (revision, patch set, out dir).
# Not packed: object files, unstripped binaries, debug symbols, build files,
# and the Dart SDK (fetch.sh links the out dir's dart-sdk to the Flutter SDK's
# own, the same Dart). [<host out name>]: take sky_engine and const_finder from
# that sibling out dir when the target's has none (a cross-built arm64 out).
set -e
src=${1:?engine/src}; out=${2:?out name}; target=${3:?target}; dest=${4:?dest dir}
host=${5:-$out}
here=$(cd "$(dirname "$0")" && pwd)
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
from=$src/out/$out
[[ -d $from ]] || { echo "no $from" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/mcsm-engine-pack.XXXXXX")
to=$stage/$target/src/out/$out
mkdir -p "$to"
# Top-level files, minus the build system's and the build-only tools.
for f in "$from"/*; do
  [[ -f $f && ! -L $f ]] || continue
  case $(basename "$f") in
    *.ninja|*.ninja.d|*.d|*.stamp|*.TOC|*.json|*.gn|*.pdb|*.exp|*.ilk|*.dylib|*.a) continue ;;
    *.tmp|gn_logs.txt|.ninja*|flatc*|analyze_snapshot*|bootstrap_compile_platform*|gen_snapshot_host_targeting_host*|shader_archiver*|*_unittests*) continue ;;
  esac
  cp -p "$f" "$to/"
done
for d in FlutterMacOS.xcframework universal flutter_patched_sdk flutter_linux cpp_client_wrapper shader_lib; do
  [[ -d $from/$d ]] && cp -pR "$from/$d" "$to/"
done
ln -s flutter_patched_sdk "$to/flutter_patched_sdk_product"
# The host-side gen_snapshot (the Flutter tool also depends on clang_*/gen_snapshot).
for c in "$from"/clang_*; do
  [[ -d $c ]] && ls "$c"/gen_snapshot* >/dev/null 2>&1 || continue
  mkdir -p "$to/$(basename "$c")"
  cp -p "$c"/gen_snapshot* "$to/$(basename "$c")/"
done
mkdir -p "$to/gen/dart-pkg"
for g in dart-pkg/sky_engine const_finder.dart.snapshot; do
  for o in "$from" "$src/out/$host"; do
    if [[ -e $o/gen/$g ]]; then cp -pR "$o/gen/$g" "$to/gen/$g"; break; fi
  done
done
patches=$(cd "$here/patches" && cat *.patch | sha256 | cut -c1-12)
cat > "$stage/$target/mcsm-engine.txt" <<EOF
target=$target
release=$(cat "$here/RELEASE")
out=$out
engine_revision=${MCSM_ENGINE_REV:-deb287481e3ce9468f3434937ced4240a70539ca}
patches=$(cd "$here/patches" && ls *.patch | tr '\n' ' ')
patches_sha256=$patches
EOF
mkdir -p "$dest"
tar -C "$stage" -cf - "$target" | xz -9 -T0 > "$dest/mcsm-engine-$target.tar.xz"
(cd "$dest" && sha256 "mcsm-engine-$target.tar.xz" > "mcsm-engine-$target.tar.xz.sha256")
du -sh "$stage/$target" "$dest/mcsm-engine-$target.tar.xz"
rm -rf "$stage"
