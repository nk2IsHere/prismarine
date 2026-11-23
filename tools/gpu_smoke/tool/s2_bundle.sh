#!/bin/bash
# s2_bundle.sh [impellerc] builds the shaders of the release 9 checks,
# s2.shaderbundle.json for Metal and Vulkan only, into
# s2_generated/s2smoke.shaderbundle before `flutter build`. It needs the
# impellerc of the patched engine, by default $PRISMARINE_IMPELLERC. The one of
# the Flutter SDK refuses these shaders. Its uniform limit is 6,208 bytes per
# shader and it has no targets per shader.
set -e
cd "$(dirname "$0")/.."
ic=${1:-${PRISMARINE_IMPELLERC:-$MCSM_IMPELLERC}}
[[ -x $ic ]] || { echo "s2_bundle: no impellerc (pass one or set PRISMARINE_IMPELLERC)"; exit 2; }
# A vertex stage that writes gl_Layer for layered passes needs MSL 2.2 or later.
"$ic" --sl=s2_generated/s2smoke.shaderbundle --metal-version=2.3 \
  --shader-bundle="$(cat s2.shaderbundle.json)"
echo "s2_bundle: s2_generated/s2smoke.shaderbundle"
