#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: Scripts/build-ds4-runtime.sh /path/to/ds4" >&2
  exit 2
fi

DS4_ROOT="$1"
if [[ ! -d "$DS4_ROOT" ]]; then
  echo "error: DS4 root not found: $DS4_ROOT" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    LIB_NAME="libds4.dylib"
    CORE_OBJS=(ds4.o ds4_distributed.o ds4_ssd.o ds4_metal.o)
    LINK_LIBS=(-framework Foundation -framework Metal -lm -pthread)
    ;;
  *)
    echo "error: build-ds4-runtime.sh currently supports macOS/Metal builds only" >&2
    exit 1
    ;;
esac

for required in ds4.c ds4.h ds4_distributed.c ds4_ssd.c ds4_metal.m Makefile; do
  if [[ ! -f "$DS4_ROOT/$required" ]]; then
    echo "error: $required not found under $DS4_ROOT" >&2
    exit 1
  fi
done

make -C "$DS4_ROOT" ds4

OBJECT_PATHS=()
for object in "${CORE_OBJS[@]}"; do
  object_path="$DS4_ROOT/$object"
  if [[ ! -f "$object_path" ]]; then
    echo "error: expected object missing after build: $object_path" >&2
    exit 1
  fi
  OBJECT_PATHS+=("$object_path")
done

cc -dynamiclib \
  -install_name "@rpath/$LIB_NAME" \
  -o "$DS4_ROOT/$LIB_NAME" \
  "${OBJECT_PATHS[@]}" \
  "${LINK_LIBS[@]}"

echo "built $DS4_ROOT/$LIB_NAME"
