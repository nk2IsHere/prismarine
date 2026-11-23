#!/bin/zsh
# build.sh [setup|patch|build|all] builds the patched Flutter engine on macOS
# into the engine directory, PRISMARINE_ENGINE_DIR.
#   setup  installs depot_tools, makes a shared clone of the Flutter SDK at its
#          engine revision, writes .gclient without Android, JDK, esbuild and
#          Fuchsia and runs gclient sync. This takes about 13 GB and 20 to 40
#          minutes of downloads.
#   patch  applies patches/*.patch on a fresh branch mcsm-engine at the
#          revision, and patches/dart/*.patch to the Dart SDK at its DEPS
#          revision, uncommitted. The engine stamps its Dart SDK hash from the
#          HEAD of that checkout, which must stay the revision that the kernel
#          files of the Flutter tool carry.
#   build  runs gn and ninja for out/host_release_arm64, or out/host_release
#          with PRISMARINE_ENGINE_CPU=x64. It builds only the targets that a
#          release `flutter build macos --local-engine` reads, about 4.5 GB and
#          an hour the first time on an M2 Pro. PRISMARINE_ENGINE_MODE=profile
#          builds out/host_profile_arm64 for profile builds, which take Dart
#          flags such as --no-inline-alloc and --profile_vm (patch 0007).
#   all    runs the three in order.
# The Flutter SDK is PRISMARINE_FLUTTER, by default the flutter on PATH. The
# build needs the Metal Toolchain, `xcodebuild -downloadComponent MetalToolchain`.
# Every PRISMARINE_ setting is also read in its MCSM_ form, and the engine
# directory defaults to $MCSM_DATA/engine or else data/engine of this checkout.
set -e
here=${0:A:h}
E=${PRISMARINE_ENGINE_DIR:-${MCSM_DATA:+$MCSM_DATA/engine}}
: ${E:=${0:A:h:h:h}/data/engine}
F=${PRISMARINE_FLUTTER:-$MCSM_FLUTTER}
if [[ -z $F ]]; then
  whence -p flutter >/dev/null || { echo "build.sh: no Flutter SDK: set PRISMARINE_FLUTTER or put flutter on PATH" >&2; exit 1; }
  F=${$(whence -p flutter):A:h:h}
fi
rev=$(cat $F/bin/internal/engine.version)
export PATH=$E/depot_tools:$PATH DEPOT_TOOLS_METRICS=0
src=$E/flutter/engine/src
step=${1:-all}

if [[ $step == setup || $step == all ]]; then
  mkdir -p $E
  [[ -d $E/depot_tools ]] || git clone -q --depth 1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git $E/depot_tools
  if [[ ! -d $E/flutter ]]; then
    git clone -q --shared --no-checkout $F $E/flutter
    git -C $E/flutter checkout -q --detach $rev
    git -C $E/flutter remote set-url origin https://github.com/flutter/flutter.git
  fi
  cat > $E/flutter/.gclient <<'EOF'
solutions = [{
  "name": ".",
  "url": "https://github.com/flutter/flutter.git",
  "deps_file": "DEPS",
  "managed": False,
  "safesync_url": "",
  "custom_deps": {},
  "custom_vars": {
    "download_android_deps": False,
    "download_jdk": False,
    "download_esbuild": False,
    "download_fuchsia_deps": False,
    "setup_githooks": False,
  },
}]
EOF
  (cd $E/flutter && gclient sync --no-history -j4)
fi

if [[ $step == patch || $step == all ]]; then
  git -C $E/flutter checkout -q -B mcsm-engine $rev
  git -C $E/flutter -c user.name="$(git -C $here config user.name)" \
    -c user.email="$(git -C $here config user.email)" am -q $here/patches/*.patch
  dart=$src/flutter/third_party/dart
  git -C $dart checkout -q -f --detach \
    $(sed -n "s/^  'dart_revision': '\([0-9a-f]*\)',/\1/p" $E/flutter/DEPS)
  git -C $dart apply $here/patches/dart/*.patch
fi

if [[ $step == build || $step == all ]]; then
  cd $src
  cpu=${PRISMARINE_ENGINE_CPU:-${MCSM_ENGINE_CPU:-arm64}}
  mode=${PRISMARINE_ENGINE_MODE:-${MCSM_ENGINE_MODE:-release}}
  out=out/host_$mode
  if [[ $cpu == arm64 ]]; then out=out/host_${mode}_arm64; fi
  ./flutter/tools/gn --runtime-mode=$mode --mac-cpu=$cpu --no-lto \
    --prebuilt-dart-sdk --no-enable-unittests
  ninja -C $out -j${PRISMARINE_ENGINE_JOBS:-${MCSM_ENGINE_JOBS:-6}} \
    flutter/shell/platform/darwin/macos:flutter_framework \
    flutter/lib/snapshot:create_macos_gen_snapshots \
    flutter/lib/snapshot:kernel_platform_files \
    flutter/sky/packages \
    flutter/flutter_frontend_server:frontend_server \
    flutter/tools/font_subset \
    flutter/tools/const_finder \
    flutter/impeller/compiler:impellerc
  # The patched SDK of a release out dir is the product one. The Flutter tool
  # looks for it under the name of its cache.
  [[ $mode == release ]] && ln -sfn flutter_patched_sdk $out/flutter_patched_sdk_product
  # PRISMARINE_ENGINE_TRIM=1 deletes the object files, 2 to 4 GB. The next
  # build of this out dir is then a full one.
  [[ -n ${PRISMARINE_ENGINE_TRIM:-$MCSM_ENGINE_TRIM} ]] && rm -rf "${src:?}/$out/obj"
  true
fi
