#!/usr/bin/env bash
# scene.sh <flutter_scene checkout> writes pubspec_overrides.yaml. It points
# gpu_smoke at that flutter_scene and at the flutter_gpu and prismarine packages
# of this checkout.
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$app/../.." && pwd)
scene=$(cd "${1:?usage: scene.sh <flutter_scene checkout>}" && pwd)
grep -q '^name: flutter_scene$' "$scene/pubspec.yaml" 2>/dev/null ||
  { echo "scene.sh: $scene has no flutter_scene package. Pass the directory of its pubspec.yaml." >&2; exit 2; }
{
  echo "# Written by tool/scene.sh."
  echo "dependency_overrides:"
  printf '  flutter_scene:\n    path: %s\n' "$scene"
  printf '  flutter_gpu:\n    path: %s\n' "$root/third_party/flutter_gpu"
  for p in "$root"/packages/prismarine_*/; do
    p=${p%/}
    printf '  %s:\n    path: %s\n' "${p##*/}" "$p"
  done
} >"$app/pubspec_overrides.yaml"
echo "$app/pubspec_overrides.yaml"
