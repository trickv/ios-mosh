#!/usr/bin/env bash
# Build mosh-oracle inside the dev container against the built mosh 1.4.0 tree.
#   scripts/dev.sh Tools/mosh-oracle/build.sh
# Output: /work/.build/mosh-oracle/mosh-oracle (the .build directory is a Docker volume).
# Env: MOSH_SRC (default /opt/mosh-src), ORACLE_OUT (default <repo>/.build/mosh-oracle).
#
# The compiler flags are the ones mosh's own Makefiles used for libmoshterminal.a and
# libmoshstatesync.a (see `make -n` in /opt/mosh-src/src/terminal), so that every class
# has the same layout here as in the libraries. The one addition is
# -fno-access-control: it lets main.cc read private members for the dump, and it only
# switches off access checking, so it cannot change a layout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MOSH_SRC="${MOSH_SRC:-/opt/mosh-src}"
OUT="${ORACLE_OUT:-$ROOT/.build/mosh-oracle}"

for lib in statesync/libmoshstatesync.a terminal/libmoshterminal.a protobufs/libmoshprotos.a util/libmoshutil.a; do
  if [ ! -f "$MOSH_SRC/src/$lib" ]; then
    echo "build.sh: $MOSH_SRC/src/$lib not found; run this inside the dev container (scripts/dev.sh)" >&2
    exit 1
  fi
done

# The predict mode links the very object mosh-client is built from.
OVERLAY_O="$MOSH_SRC/src/frontend/terminaloverlay.o"
if [ ! -f "$OVERLAY_O" ]; then
  echo "build.sh: $OVERLAY_O not found; the mosh tree must be built (make in $MOSH_SRC)" >&2
  exit 1
fi

mkdir -p "$OUT"
# Same as mosh: c++ -std=gnu++11 -DHAVE_CONFIG_H ... -g -O2
c++ -std=gnu++11 -DHAVE_CONFIG_H \
  -I"$MOSH_SRC/src/include" -I"$MOSH_SRC/src/util" -I"$MOSH_SRC/src/terminal" \
  -I"$MOSH_SRC/src/statesync" -I"$MOSH_SRC/src/protobufs" \
  -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600 \
  -Wall -fno-strict-overflow -D_FORTIFY_SOURCE=2 -fstack-protector-all -Wstack-protector \
  --param ssp-buffer-size=1 -fPIE -fno-default-inline -pipe -g -O2 \
  -fno-access-control \
  -c "$HERE/main.cc" -o "$OUT/main.o"
# predict.cc includes terminaloverlay.h, which needs the network and crypto headers (the
# include path of mosh's frontend Makefile).
c++ -std=gnu++11 -DHAVE_CONFIG_H \
  -I"$MOSH_SRC/src/include" -I"$MOSH_SRC/src/util" -I"$MOSH_SRC/src/terminal" \
  -I"$MOSH_SRC/src/statesync" -I"$MOSH_SRC/src/protobufs" \
  -I"$MOSH_SRC/src/network" -I"$MOSH_SRC/src/crypto" -I"$MOSH_SRC/src/frontend" \
  -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600 \
  -Wall -fno-strict-overflow -D_FORTIFY_SOURCE=2 -fstack-protector-all -Wstack-protector \
  --param ssp-buffer-size=1 -fPIE -fno-default-inline -pipe -g -O2 \
  -fno-access-control \
  -c "$HERE/predict.cc" -o "$OUT/predict.o"
c++ -pie -Wl,-z,relro -Wl,-z,now -o "$OUT/mosh-oracle.tmp" "$OUT/main.o" "$OUT/predict.o" "$OVERLAY_O" \
  "$MOSH_SRC/src/statesync/libmoshstatesync.a" "$MOSH_SRC/src/terminal/libmoshterminal.a" \
  "$MOSH_SRC/src/protobufs/libmoshprotos.a" "$MOSH_SRC/src/util/libmoshutil.a" \
  -lprotobuf -ltinfo -lz
mv "$OUT/mosh-oracle.tmp" "$OUT/mosh-oracle"
echo "built $OUT/mosh-oracle" >&2
