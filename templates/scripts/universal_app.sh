#!/bin/zsh
# universal_app.sh <arm64.app> <x86_64.app> <out.app> merges two builds of a
# macOS app, one for each CPU, into one universal app. An app built on the
# patched engine is for the CPU of the engine only. Build it once on
# host_release_arm64 and once on host_release, copy each .app aside and merge
# them here. Each Mach-O file becomes a universal file through lipo. The other
# files must be equal, except the native assets manifest, whose entries of both
# CPUs are kept. The result has an ad hoc signature.
set -e
[[ $# -eq 3 && -d $1 && -d $2 && $3 == *.app ]] || { echo "usage: $0 <arm64.app> <x86_64.app> <out.app>" >&2; exit 2; }
arm=${1:A}; x64=${2:A}; out=${3:A}
rm -rf "${out:?}"
cp -c -R $arm $out
n=0
for f in $(cd $arm && find . -type f); do
  if file -b "$arm/$f" | grep -q '^Mach-O'; then
    [[ -f "$x64/$f" ]] || { echo "missing in x86_64 build: $f" >&2; exit 1; }
    # A library that has both CPUs already, such as a cached hook output, is
    # kept as it is.
    if [[ " $(lipo -archs "$arm/$f") " != *" x86_64 "* ]]; then
      lipo -create "$arm/$f" "$x64/$f" -output "$out/$f"
      n=$((n + 1))
    fi
  elif ! cmp -s "$arm/$f" "$x64/$f"; then
    case $f in
      # The signature is made again below.
      */_CodeSignature/*|*/CodeResources) ;;
      # The revision string of the engine is for information. The one of the
      # arm64 build is kept.
      */FlutterMacOS.framework/Versions/A/Resources/Info.plist) ;;
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
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $out/Contents/Info.plist)
echo "$out: $n Mach-O files merged ($(lipo -archs $out/Contents/MacOS/$exe))"
