#!/bin/zsh
# universal_app.sh <arm64.app> <x86_64.app> <out.app>: merges two
# single-architecture builds of the player into one universal app.
#
# Why: with a local engine (MCSM_LOCAL_ENGINE) the Flutter tool builds a macOS
# app for the local engine's one architecture only (it sets ARCHS from the
# engine's name: `_arm64` → arm64, otherwise x86_64; xcode_build_settings.dart).
# Build once per engine (MCSM_LOCAL_ENGINE_NAME=host_release_arm64 and
# host_release), copy each .app aside, then merge them here: every Mach-O file
# becomes a fat file (lipo), everything else must be identical, and the result
# is signed ad hoc.
set -e
[[ $# -eq 3 && -d $1 && -d $2 && $3 == *.app ]] || { echo "usage: $0 <arm64.app> <x86_64.app> <out.app>" >&2; exit 2; }
arm=${1:A}; x64=${2:A}; out=${3:A}
rm -rf "${out:?}"
cp -c -R $arm $out
n=0
for f in $(cd $arm && find . -type f); do
  if file -b "$arm/$f" | grep -q '^Mach-O'; then
    [[ -f "$x64/$f" ]] || { echo "missing in x86_64 build: $f" >&2; exit 1; }
    # A library that is already universal (a cached hook output) stays as is.
    if [[ " $(lipo -archs "$arm/$f") " != *" x86_64 "* ]]; then
      lipo -create "$arm/$f" "$x64/$f" -output "$out/$f"
      n=$((n + 1))
    fi
  elif ! cmp -s "$arm/$f" "$x64/$f"; then
    case $f in
      */_CodeSignature/*|*/CodeResources) ;;  # re-signed below
      # The engine's revision string (informational): the arm64 build's stays.
      */FlutterMacOS.framework/Versions/A/Resources/Info.plist) ;;
      # Native assets per architecture (macos_arm64, macos_x64): both kept.
      */NativeAssetsManifest.json)
        python3 -I -c 'import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
a["native-assets"].update(b["native-assets"])
json.dump(a, open(sys.argv[3], "w"))' "$arm/$f" "$x64/$f" "$out/$f" ;;
      *) echo "differs between the builds: $f" >&2; exit 1 ;;
    esac
  fi
done
codesign --force --deep -s - $out > /dev/null
echo "$out: $n Mach-O files merged ($(lipo -archs $out/Contents/MacOS/mcsm_player))"
