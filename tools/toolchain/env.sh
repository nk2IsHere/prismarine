# env.sh sets the toolchain of this machine in the shell that sources it, bash
# or zsh. Each machine has one Flutter SDK, one pub cache and one engine
# directory, which every repository on it uses. The README beside this file
# lists the variables and the default folders.
#
# A folder that is a symbolic link is used under its real path. A missing
# Flutter SDK or pub cache leaves PATH or PUB_CACHE as they are.

prismarine_real() { (cd -P "$1" 2>/dev/null && pwd); }

PRISMARINE_FLUTTER=${PRISMARINE_FLUTTER:-$HOME/.prismarine/flutter}
if [[ -x $PRISMARINE_FLUTTER/bin/flutter ]]; then
  PRISMARINE_FLUTTER=$(prismarine_real "$PRISMARINE_FLUTTER")
  export PRISMARINE_FLUTTER PATH=$PRISMARINE_FLUTTER/bin:$PATH
else
  unset PRISMARINE_FLUTTER
fi

PRISMARINE_PUB_CACHE=${PRISMARINE_PUB_CACHE:-$HOME/.prismarine/pub-cache}
if [[ -d $PRISMARINE_PUB_CACHE ]]; then
  PRISMARINE_PUB_CACHE=$(prismarine_real "$PRISMARINE_PUB_CACHE")
  export PRISMARINE_PUB_CACHE PUB_CACHE=$PRISMARINE_PUB_CACHE
else
  unset PRISMARINE_PUB_CACHE
fi

PRISMARINE_ENGINE_DIR=${PRISMARINE_ENGINE_DIR:-$HOME/.prismarine/engine}
if [[ -d $PRISMARINE_ENGINE_DIR ]]; then PRISMARINE_ENGINE_DIR=$(prismarine_real "$PRISMARINE_ENGINE_DIR"); fi
export PRISMARINE_ENGINE_DIR

# The out dir of a release engine for this machine and the folder of a fetched
# engine of the same target.
case $(uname -s)-$(uname -m) in
  Darwin-arm64) prismarine_engine_target=macos-arm64 prismarine_engine_out=host_release_arm64 ;;
  Darwin-x86_64) prismarine_engine_target=macos-x64 prismarine_engine_out=host_release ;;
  Linux-x86_64) prismarine_engine_target=linux-x64 prismarine_engine_out=host_release ;;
  Linux-aarch64 | Linux-arm64) prismarine_engine_target=linux-arm64 prismarine_engine_out=linux_release_arm64 ;;
  *) prismarine_engine_target= prismarine_engine_out= ;;
esac

# The flags of a release `flutter build` on the patched engine, a fetched one
# before a built one. The array is empty when the machine has neither, and the
# build then runs on the stock engine.
prismarine_engine_args=()
prismarine_engine_src=
for prismarine_c in "$PRISMARINE_ENGINE_DIR/$prismarine_engine_target/src" "$PRISMARINE_ENGINE_DIR/flutter/engine/src"; do
  if [[ -n $prismarine_engine_out && -e $prismarine_c/out/$prismarine_engine_out/flutter_patched_sdk_product ]]; then
    prismarine_engine_src=$prismarine_c
    break
  fi
done
unset prismarine_c
if [[ -n $prismarine_engine_src ]]; then
  prismarine_engine_args=(--local-engine-src-path="$prismarine_engine_src"
    --local-engine="$prismarine_engine_out" --local-engine-host="$prismarine_engine_out")
  if [[ -z ${PRISMARINE_IMPELLERC:-} && -x $prismarine_engine_src/out/$prismarine_engine_out/impellerc ]]; then
    export PRISMARINE_IMPELLERC=$prismarine_engine_src/out/$prismarine_engine_out/impellerc
  fi
fi
