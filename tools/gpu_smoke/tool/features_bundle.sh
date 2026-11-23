#!/bin/bash
# features_bundle.sh [impellerc] builds the shaders of the release 9 checks,
# features.shaderbundle.json for Metal and Vulkan only, into
# features_generated/features.shaderbundle before `flutter build`. It needs the
# impellerc of the patched engine, by default $PRISMARINE_IMPELLERC. The one of
# the Flutter SDK refuses these shaders. Its uniform limit is 6,208 bytes per
# shader and it has no targets per shader.
set -e
cd "$(dirname "$0")/.."
ic=${1:-${PRISMARINE_IMPELLERC:-$MCSM_IMPELLERC}}
[[ -x $ic ]] || { echo "features_bundle: no impellerc (pass one or set PRISMARINE_IMPELLERC)"; exit 2; }
# A vertex stage that writes gl_Layer for layered passes needs MSL 2.2 or later.
"$ic" --sl=features_generated/features.shaderbundle --metal-version=2.3 \
  --shader-bundle="$(cat features.shaderbundle.json)"
echo "features_bundle: features_generated/features.shaderbundle"
