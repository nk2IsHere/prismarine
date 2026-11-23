#!/bin/bash
# linux.sh [setup|build|test|all] on a Linux x86_64 host, with
# MCSM_ENGINE_DIR=<a dir with ~30 GB free> (e.g. $HOME/mcsm-engine): the patched engine for Linux
# x64 (out/host_release) and arm64 (cross, out/linux_release_arm64, with the
# engine's Debian sysroot), plus a debug test build (out/host_debug_unopt_tests:
# gpu_unittests, impeller_unittests on SwiftShader). Needs git, python3, curl,
# xz-utils and pkg-config (gclient brings the compiler and the Debian sysroots);
# patches from this directory. ~11 GB of sources, ~1 GB per release out dir,
# 5.4 GB for the test build; ~10 + 13 min on 16 cores (MCSM_ENGINE_JOBS, default 10).
set -e
here=$(cd "$(dirname "$0")" && pwd)
E=${MCSM_ENGINE_DIR:?set MCSM_ENGINE_DIR}
rev=${MCSM_ENGINE_REV:-deb287481e3ce9468f3434937ced4240a70539ca}
J=${MCSM_ENGINE_JOBS:-10}
export PATH=$E/depot_tools:$PATH DEPOT_TOOLS_METRICS=0
step=${1:-all}
if [[ $step == setup || $step == all ]]; then
  mkdir -p $E && cd $E
  [[ -d depot_tools ]] || git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
  [[ -d flutter ]] || { git clone -q --filter=blob:none --no-checkout https://github.com/flutter/flutter.git flutter; git -C flutter checkout -q --detach $rev; }
  cd flutter
  git checkout -q -B mcsm-engine $rev
  git -c user.name=mcsm -c user.email=mcsm@localhost am -q $here/patches/*.patch
  cat > .gclient <<'G'
solutions = [{"name": ".", "url": "https://github.com/flutter/flutter.git",
  "deps_file": "DEPS", "managed": False, "safesync_url": "", "custom_deps": {},
  "custom_vars": {"download_android_deps": False, "download_jdk": False,
    "download_esbuild": False, "download_fuchsia_deps": False, "setup_githooks": False}}]
target_os = ["linux"]
G
  gclient sync --no-history -j8
  # The Dart SDK's patches, uncommitted at its DEPS revision (build.sh
  # "patch"): patch 0028 calls the VM's Dart_McsmIdle (dart/0002), 0029
  # its Dart_McsmOldSpace (dart/0003).
  dart=engine/src/flutter/third_party/dart
  git -C $dart checkout -q -f --detach \
    $(sed -n "s/^  'dart_revision': '\([0-9a-f]*\)',/\1/p" DEPS)
  git -C $dart apply $here/patches/dart/*.patch
fi
cd $E/flutter/engine/src
if [[ $step == build || $step == all ]]; then
  ./flutter/tools/gn --runtime-mode=release --no-lto --prebuilt-dart-sdk --no-enable-unittests
  ninja -C out/host_release -j$J flutter/shell/platform/linux:flutter_gtk \
    flutter/lib/snapshot:generate_snapshot_bins flutter/lib/snapshot:kernel_platform_files \
    flutter/sky/packages flutter/flutter_frontend_server:frontend_server \
    flutter/tools/font_subset flutter/tools/const_finder flutter/impeller/compiler:impellerc
  ln -sfn flutter_patched_sdk out/host_release/flutter_patched_sdk_product
  ./flutter/tools/gn --runtime-mode=release --target-os=linux --linux-cpu=arm64 --no-lto --prebuilt-dart-sdk --no-enable-unittests
  ninja -C out/linux_release_arm64 -j$J flutter/shell/platform/linux:flutter_gtk \
    flutter/lib/snapshot:generate_snapshot_bins flutter/lib/snapshot:kernel_platform_files
  ln -sfn flutter_patched_sdk out/linux_release_arm64/flutter_patched_sdk_product
fi
if [[ $step == test || $step == all ]]; then
  ./flutter/tools/gn --runtime-mode=debug --unoptimized --prebuilt-dart-sdk --use-glfw-swiftshader --target-dir=host_debug_unopt_tests
  ninja -C out/host_debug_unopt_tests -j$J flutter/lib/gpu:gpu_unittests flutter/impeller:impeller_unittests
  # The CommandBuffer suite aborts in debug builds on an upstream test bug (a
  # ref-counted object on the stack); the suites our patches touch:
  out/host_debug_unopt_tests/gpu_unittests '--gtest_filter=FlutterGpuRenderPassTest.*:FlutterGpuShaderLibraryTest.*'
  echo "impeller_unittests (Vulkan on SwiftShader) need a display: see README.md (Building on Linux)."
fi
