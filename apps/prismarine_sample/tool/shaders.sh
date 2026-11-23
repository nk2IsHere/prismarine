#!/bin/bash
# shaders.sh [impellerc] builds the shaders of prismarine_pbr into
# shaders_generated/ of the app, which a build of the app carries. It needs
# the impellerc of the patched engine, by default $PRISMARINE_IMPELLERC.
set -e
app=$(cd "$(dirname "$0")/.." && pwd)
pbr=$app/../../packages/prismarine_pbr
ic=${1:-${PRISMARINE_IMPELLERC:-$MCSM_IMPELLERC}}
[[ -x $ic ]] || { echo "shaders: no impellerc. Pass one or set PRISMARINE_IMPELLERC."; exit 2; }
cd "$pbr"
[[ -f .dart_tool/package_config.json ]] || flutter pub get >/dev/null
dart tool/build_shaders.dart "$app/shaders_generated" --impellerc="$ic"
