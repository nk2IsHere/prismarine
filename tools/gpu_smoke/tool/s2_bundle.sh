#!/bin/bash
# s2_bundle.sh [impellerc]: builds S2's smoke shaders (s2.shaderbundle.json,
# Metal and Vulkan only) into s2_generated/s2smoke.shaderbundle with the
# patched engine's impellerc (the SDK's refuses them: its uniform limit is
# 6,208 bytes per shader and it knows no per-shader targets), before
# `flutter build`. Default: $MCSM_IMPELLERC (tools/toolchain/env.sh).
set -e
cd "$(dirname "$0")/.."
ic=${1:-${PRISMARINE_IMPELLERC:-$MCSM_IMPELLERC}}
[[ -x $ic ]] || { echo "s2_bundle: no impellerc (pass one or set PRISMARINE_IMPELLERC)"; exit 2; }
# MSL 2.2 at least: a vertex stage writing gl_Layer (layered passes).
"$ic" --sl=s2_generated/s2smoke.shaderbundle --metal-version=2.3 \
  --shader-bundle="$(cat s2.shaderbundle.json)"
echo "s2_bundle: s2_generated/s2smoke.shaderbundle"
