#!/bin/bash
# Build moshref (mosh 1.4.0's own terminal as a reference for the Swift port).
#   build-moshref.sh OUTDIR        writes OUTDIR/moshref
# Needs the built mosh source tree (MOSH_SRC, default /opt/mosh-src, as in the dev
# container) and g++ with the protobuf library. Linux only.
set -euo pipefail
OUT="${1:?usage: build-moshref.sh OUTDIR}"
MOSH_SRC="${MOSH_SRC:-/opt/mosh-src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
# The same language level and config.h as the mosh build, so that class layouts match
# the prebuilt static libraries.
g++ -std=gnu++11 -O1 -g -DHAVE_CONFIG_H -Wall \
  -I"$MOSH_SRC/src/include" -I"$MOSH_SRC/src/util" -I"$MOSH_SRC/src/terminal" \
  -I"$MOSH_SRC/src/statesync" -I"$MOSH_SRC/src/protobufs" \
  -o "$OUT/moshref" "$HERE/moshref.cc" \
  "$MOSH_SRC/src/statesync/libmoshstatesync.a" \
  "$MOSH_SRC/src/terminal/libmoshterminal.a" \
  "$MOSH_SRC/src/protobufs/libmoshprotos.a" \
  "$MOSH_SRC/src/util/libmoshutil.a" \
  -lprotobuf -ltinfo -lz
