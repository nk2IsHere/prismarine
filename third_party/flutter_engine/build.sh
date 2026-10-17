#!/bin/zsh
# build.sh [setup|patch|build|all]: the patched Flutter engine for mcsm (perf E).
#   setup  depot_tools, a shared clone of $MCSM_FLUTTER at the engine revision,
#          .gclient (no Android, JDK, esbuild, Fuchsia) and `gclient sync`
#          (~13 GB in $MCSM_DATA/engine; network, 20–40 min).
#   patch  applies patches/*.patch on a branch `mcsm-engine` (idempotent: a
#          fresh branch from the revision each time).
#   build  gn + ninja for out/host_release_arm64 (MCSM_ENGINE_CPU=x64:
#          out/host_release, an x86_64 engine): only the targets a release
#          `flutter build macos --local-engine` reads (~4.5 GB; ~1 h the first
#          time on the M2 Pro, a few minutes after a lib/gpu edit).
#   all    the three in order.
# Then set MCSM_LOCAL_ENGINE=$MCSM_DATA/engine/flutter/engine/src in .env.
# Needs the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
set -e
source ${0:A:h:h:h}/tools/toolchain/env.sh
here=${0:A:h}
E=$MCSM_DATA/engine
rev=$(cat $MCSM_FLUTTER/bin/internal/engine.version)
export PATH=$E/depot_tools:$PATH DEPOT_TOOLS_METRICS=0
src=$E/flutter/engine/src
step=${1:-all}

if [[ $step == setup || $step == all ]]; then
  mkdir -p $E
  [[ -d $E/depot_tools ]] || git clone -q --depth 1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git $E/depot_tools
  if [[ ! -d $E/flutter ]]; then
    git clone -q --shared --no-checkout $MCSM_FLUTTER $E/flutter
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
fi

if [[ $step == build || $step == all ]]; then
  cd $src
  cpu=${MCSM_ENGINE_CPU:-arm64}
  out=out/host_release
  if [[ $cpu == arm64 ]]; then out=out/host_release_arm64; fi
  ./flutter/tools/gn --runtime-mode=release --mac-cpu=$cpu --no-lto \
    --prebuilt-dart-sdk --no-enable-unittests
  ninja -C $out -j${MCSM_ENGINE_JOBS:-6} \
    flutter/shell/platform/darwin/macos:flutter_framework \
    flutter/lib/snapshot:create_macos_gen_snapshots \
    flutter/lib/snapshot:kernel_platform_files \
    flutter/sky/packages \
    flutter/flutter_frontend_server:frontend_server \
    flutter/tools/font_subset \
    flutter/tools/const_finder
  # A release out dir's patched SDK is the product one; the Flutter tool looks
  # for it under the cache's name.
  ln -sfn flutter_patched_sdk $out/flutter_patched_sdk_product
  # MCSM_ENGINE_TRIM=1: drop the object files (~2–4 GB); the next build of
  # this out dir is then a full one.
  [[ -n $MCSM_ENGINE_TRIM ]] && rm -rf "${src:?}/$out/obj"
  true
fi
