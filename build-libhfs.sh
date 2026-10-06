#!/bin/bash
set -e

# Builds a universal (arm64 + x86_64) libhfs.a for the app from hfsutils/libhfs
# Usage: ./build-libhfs.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/hfsutils/libhfs"
OUT="$SCRIPT_DIR/com.maxleiter.HFSViewer/libs/libhfs.a"
MIN_MACOS="14.0"

OBJ_DIR=$(mktemp -d)
trap 'rm -rf "$OBJ_DIR"' EXIT

echo "→ Compiling libhfs..."
for f in os data block low medium file btree node record volume hfs version; do
  clang -c "$SRC/$f.c" -o "$OBJ_DIR/$f.o" \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$MIN_MACOS" \
    -O2 -DHAVE_MKTIME
done

rm -f "$OUT"
# Zero the archive timestamps so rebuilding unchanged sources gives an identical file
ZERO_AR_DATE=1 libtool -static -o "$OUT" "$OBJ_DIR"/*.o

echo "✓ Built $OUT ($(lipo -archs "$OUT"))"
