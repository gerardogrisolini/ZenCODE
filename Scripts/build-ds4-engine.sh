#!/usr/bin/env bash
#
# build-ds4-engine.sh - build libzencode-ds4.{dylib,so}, the ZenCODE in-process
# DS4 engine.
#
# The library is the ZenCODE-owned C shim (zencode_ds4_shim.c, ABI declared in
# zencode_ds4_abi.h) compiled against ds4.h of the user's DS4 checkout and linked
# with the objects of the DS4 Makefile.  ZenCODE loads it with dlopen() at
# runtime and never links DS4 at compile time.
#
# Usage:
#   build-ds4-engine.sh --root <dir> --backend metal|cpu|cuda|rocm
#                       [--cuda-arch A] [--rocm-arch A]
#                       --shim <dir> --output <file>
#
# Options:
#   --root <dir>        DS4 checkout (contains ds4.h and the Makefile).
#   --backend <name>    metal (macOS), cpu (Linux/macOS), cuda or rocm (Linux).
#   --cuda-arch <arch>  nvcc architecture, for example sm_120 or native
#                       (default: native).  CUDA backend only.
#   --rocm-arch <arch>  ROCm target, for example gfx1151 (default: gfx1151).
#                       ROCm backend only.
#   --shim <dir>        Directory with zencode_ds4_shim.c and zencode_ds4_abi.h.
#   --output <file>     Library to produce (.../libzencode-ds4.dylib or .so).
#                       build.json is written next to it.
#   -h, --help          Show this help.
#
# Environment:
#   CC, CUDA_HOME, NVCC, HIPCC   Toolchain overrides, honoured like the DS4 Makefile.
#   ZENCODE_DS4_BUILD_JOBS       Parallel make jobs (default: min(CPU count, 4)).
#
# Only the DS4 objects that are linked into the library are (re)built, by name:
# the other DS4 programs in the checkout are neither rebuilt nor relinked and
# `make clean` is never run.  On Linux those objects are deleted first so that
# they are regenerated position independent (-fPIC), which make cannot detect.
#
# Requires bash 3.2 or newer (macOS /bin/bash) and a POSIX userland.

set -euo pipefail

usage() {
    sed -n '3,/^# Requires bash/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^Requires bash/d'
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '==> %s\n' "$*"
}

# Prints a command (shell-quoted) and runs it.
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------

ROOT=""
BACKEND=""
CUDA_ARCH_ARG=""
ROCM_ARCH_ARG=""
SHIM_DIR=""
OUTPUT=""

need_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || {
        printf 'error: %s needs a value\n' "$1" >&2
        usage >&2
        exit 2
    }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --root|--backend|--cuda-arch|--rocm-arch|--shim|--output)
            need_value "$@"
            case "$1" in
                --root) ROOT="$2" ;;
                --backend) BACKEND="$2" ;;
                --cuda-arch) CUDA_ARCH_ARG="$2" ;;
                --rocm-arch) ROCM_ARCH_ARG="$2" ;;
                --shim) SHIM_DIR="$2" ;;
                --output) OUTPUT="$2" ;;
            esac
            shift 2
            ;;
        --root=*) ROOT="${1#*=}"; shift ;;
        --backend=*) BACKEND="${1#*=}"; shift ;;
        --cuda-arch=*) CUDA_ARCH_ARG="${1#*=}"; shift ;;
        --rocm-arch=*) ROCM_ARCH_ARG="${1#*=}"; shift ;;
        --shim=*) SHIM_DIR="${1#*=}"; shift ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        *)
            printf 'error: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$ROOT" ] || { printf 'error: --root is required\n' >&2; usage >&2; exit 2; }
[ -n "$BACKEND" ] || { printf 'error: --backend is required\n' >&2; usage >&2; exit 2; }
[ -n "$SHIM_DIR" ] || { printf 'error: --shim is required\n' >&2; usage >&2; exit 2; }
[ -n "$OUTPUT" ] || { printf 'error: --output is required\n' >&2; usage >&2; exit 2; }

case "$BACKEND" in
    metal|cpu|cuda|rocm) ;;
    *) die "unknown backend '$BACKEND' (expected metal, cpu, cuda or rocm)" ;;
esac

valid_arch() {
    case "$1" in
        ''|*[!A-Za-z0-9_.+:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

ARCH=""
case "$BACKEND" in
    cuda)
        ARCH="${CUDA_ARCH_ARG:-native}"
        ;;
    rocm)
        ARCH="${ROCM_ARCH_ARG:-gfx1151}"
        ;;
esac
if [ -n "$ARCH" ] && ! valid_arch "$ARCH"; then
    die "invalid architecture '$ARCH' (allowed characters: letters, digits, _ . + : -)"
fi

# ----------------------------------------------------------------------------
# Paths and host checks
# ----------------------------------------------------------------------------

[ -d "$ROOT" ] || die "DS4 root directory not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
[ -d "$SHIM_DIR" ] || die "shim directory not found: $SHIM_DIR"
SHIM_DIR="$(cd "$SHIM_DIR" && pwd -P)"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac
OUT_DIR="$(dirname "$OUTPUT")"
OUT_NAME="$(basename "$OUTPUT")"
OUT_JSON="$OUT_DIR/build.json"

HOST_OS="$(uname -s)"
case "$BACKEND" in
    metal)
        [ "$HOST_OS" = "Darwin" ] || die "the metal backend requires macOS (host is $HOST_OS)"
        ;;
    cuda|rocm)
        [ "$HOST_OS" = "Linux" ] || die "the $BACKEND backend requires Linux (host is $HOST_OS)"
        ;;
    cpu)
        case "$HOST_OS" in
            Darwin|Linux) ;;
            *) die "unsupported host OS: $HOST_OS" ;;
        esac
        ;;
esac

require_file() {
    [ -f "$1" ] || die "$2 is missing: $1"
}

require_file "$ROOT/Makefile" "DS4 Makefile"
require_file "$ROOT/ds4.h" "DS4 header"
require_file "$ROOT/ds4.c" "DS4 engine source"
require_file "$ROOT/ds4_kvstore.c" "DS4 source"
require_file "$ROOT/ds4_kvstore.h" "DS4 header"
require_file "$ROOT/ds4_gpu_args.c" "DS4 source"
require_file "$ROOT/ds4_gpu_args.h" "DS4 header"
require_file "$ROOT/ds4_distributed.h" "DS4 header"
require_file "$ROOT/ds4_tp.h" "DS4 header"
case "$BACKEND" in
    metal)
        require_file "$ROOT/ds4_metal.m" "DS4 Metal source"
        [ -d "$ROOT/metal" ] || die "DS4 Metal kernels directory is missing: $ROOT/metal"
        ;;
    cuda)
        require_file "$ROOT/ds4_cuda.cu" "DS4 CUDA source"
        [ -d "$ROOT/cuda/mmq" ] || die "DS4 CUDA mmq directory is missing: $ROOT/cuda/mmq"
        ;;
    rocm)
        require_file "$ROOT/ds4_rocm.cu" "DS4 ROCm source"
        [ -d "$ROOT/cuda/mmq" ] || die "DS4 mmq directory is missing: $ROOT/cuda/mmq"
        ;;
esac
SHIM_SOURCE="$SHIM_DIR/zencode_ds4_shim.c"
SHIM_ABI_HEADER="$SHIM_DIR/zencode_ds4_abi.h"
require_file "$SHIM_SOURCE" "ZenCODE shim source"
require_file "$SHIM_ABI_HEADER" "ZenCODE shim ABI header"

CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || die "C compiler not found: $CC_BIN"
command -v make >/dev/null 2>&1 || die "make not found"

# ----------------------------------------------------------------------------
# Scratch space and cleanup
# ----------------------------------------------------------------------------

WORK=""
TMP_OUT=""
TMP_JSON=""

cleanup() {
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    if [ -n "$TMP_OUT" ]; then rm -f "$TMP_OUT"; fi
    if [ -n "$TMP_JSON" ]; then rm -f "$TMP_JSON"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zencode-ds4-build.XXXXXX")"

# ----------------------------------------------------------------------------
# Per-backend configuration
# ----------------------------------------------------------------------------

# Flags of the DS4 Makefile on Linux (CFLAGS default plus the Linux additions)
# with -fPIC, for objects that end up in a shared library.
LINUX_CFLAGS='-O3 -ffast-math -g -march=native -Wall -Wextra -std=c99 -D_GNU_SOURCE -fno-finite-math-only -fPIC'

# Objects linked into the library, relative to the DS4 root (verified against
# the Makefile: CORE_OBJS / CPU_CORE_OBJS / MMQ_OBJS / the strix-halo target,
# plus ds4_kvstore.o and the GPU argument parser used by the shim).
MMQ_OBJS="cuda/mmq/ds4_ggml_stubs.o cuda/mmq/ds4_mmq.o cuda/mmq/ds4_mmq_d2r.o cuda/mmq/quantize.o cuda/mmq/mmid.o cuda/mmq/mmvq.o cuda/mmq/ds4_repack.o"
ROCM_MMQ_OBJS="cuda/mmq/ds4_ggml_stubs.rocm.o cuda/mmq/ds4_mmq.rocm.o cuda/mmq/quantize.rocm.o cuda/mmq/mmid.rocm.o cuda/mmq/mmvq.rocm.o cuda/mmq/d2r_stubs.rocm.o"

MAKE_OVERRIDES=()
SHIM_CFLAGS=(-std=c99 -O2 -Wall -Wextra)
case "$BACKEND" in
    metal)
        OBJECTS="ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_metal.o ds4_layer_pack.o ds4_engram.o ds4_kvstore.o ds4_gpu_args.o"
        ;;
    cpu)
        OBJECTS="ds4_cpu.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_layer_pack.o ds4_kvstore.o ds4_gpu_args_cpu.o"
        SHIM_CFLAGS+=(-DDS4_NO_GPU)
        if [ "$HOST_OS" = "Linux" ]; then
            MAKE_OVERRIDES=("CFLAGS=$LINUX_CFLAGS")
            SHIM_CFLAGS+=(-D_GNU_SOURCE -fPIC)
        fi
        ;;
    cuda)
        OBJECTS="ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_cuda.o ds4_layer_pack.o ds4_engram.o $MMQ_OBJS ds4_kvstore.o ds4_gpu_args.o"
        MAKE_OVERRIDES=(
            "CUDA_ARCH=$ARCH"
            "CFLAGS=$LINUX_CFLAGS"
            'NVCCFLAGS=-O3 -g -lineinfo --use_fast_math $(NVCC_ARCH_FLAGS) -Xcompiler -march=native -Xcompiler -pthread -Xcompiler -fPIC'
        )
        SHIM_CFLAGS+=(-D_GNU_SOURCE -fPIC)
        ;;
    rocm)
        OBJECTS="ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_rocm.o ds4_rocm_compat.o ds4_rocm_unavailable.o ds4_layer_pack.o ds4_engram.o $ROCM_MMQ_OBJS ds4_kvstore.o ds4_gpu_args.o"
        MAKE_OVERRIDES=(
            "ROCM_ARCH=$ARCH"
            "CFLAGS=$LINUX_CFLAGS -DDS4_ROCM_BUILD"
            'ROCM_CFLAGS=-O3 -ffast-math -g -fno-finite-math-only -pthread -D__HIP_PLATFORM_AMD__ -Wno-unused-command-line-argument --offload-arch=$(ROCM_ARCH) -fPIC'
        )
        SHIM_CFLAGS+=(-D_GNU_SOURCE -fPIC -DDS4_ROCM_BUILD)
        ;;
esac

# Prints the value of a Makefile variable as make expands it with the same
# overrides used for the build (lazy references such as $(NVCC_ARCH_FLAGS) in
# the overrides are resolved by the DS4 Makefile itself).
VARS_MK="$WORK/vars.mk"
printf 'zen-var-%%:\n\t@echo '"'"'$($*)'"'"'\n' > "$VARS_MK"

make_var() {
    make -s -C "$ROOT" -f "$ROOT/Makefile" -f "$VARS_MK" \
        ${MAKE_OVERRIDES[@]+"${MAKE_OVERRIDES[@]}"} "zen-var-$1" 2>/dev/null
}

# Splits a whitespace separated string into the global array SPLIT_RESULT.
split_words() {
    SPLIT_RESULT=()
    local word
    for word in $1; do
        SPLIT_RESULT+=("$word")
    done
}

NVCC_BIN=""
HIPCC_BIN=""
LINK_FLAGS=()
LINK_LIBS=()
case "$BACKEND" in
    cuda)
        NVCC_BIN="$(make_var NVCC || true)"
        [ -n "$NVCC_BIN" ] && command -v "$NVCC_BIN" >/dev/null 2>&1 \
            || die "nvcc not found (looked for '${NVCC_BIN:-nvcc}'). Install the CUDA toolkit or set CUDA_HOME/NVCC, then retry."
        split_words "$(make_var NVCCFLAGS || true)"
        LINK_FLAGS=(${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"})
        split_words "$(make_var CUDA_LDLIBS || true)"
        LINK_LIBS=(${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"})
        # Let dlopen() resolve libcudart/libcublas from the toolkit used to link.
        for word in ${LINK_LIBS[@]+"${LINK_LIBS[@]}"}; do
            case "$word" in
                -L?*)
                    if [ -d "${word#-L}" ]; then
                        LINK_LIBS+=(-Xlinker -rpath -Xlinker "${word#-L}")
                    fi
                    ;;
            esac
        done
        ;;
    rocm)
        HIPCC_BIN="$(make_var HIPCC || true)"
        [ -n "$HIPCC_BIN" ] && command -v "$HIPCC_BIN" >/dev/null 2>&1 \
            || die "hipcc not found (looked for '${HIPCC_BIN:-hipcc}'). Install ROCm (/opt/rocm) or set HIPCC, then retry."
        split_words "$(make_var ROCM_CFLAGS || true)"
        LINK_FLAGS=(${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"})
        split_words "$(make_var ROCM_LDLIBS || true)"
        LINK_LIBS=(${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"})
        ;;
    metal)
        LINK_LIBS=(-framework Foundation -framework Metal -lm -pthread)
        ;;
    cpu)
        LINK_LIBS=(-lm -pthread)
        ;;
esac

# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------

step "Building the ZenCODE DS4 engine ($BACKEND${ARCH:+, $ARCH}) from $ROOT"

if [ "$HOST_OS" = "Linux" ]; then
    step "Removing the DS4 objects linked into the library so they are rebuilt with -fPIC"
    (cd "$ROOT" && rm -f $OBJECTS)
fi

JOBS="${ZENCODE_DS4_BUILD_JOBS:-}"
if [ -z "$JOBS" ]; then
    JOBS="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1) | head -n 1 )"
    case "$JOBS" in
        ''|*[!0-9]*) JOBS=1 ;;
    esac
    if [ "$JOBS" -gt 4 ]; then JOBS=4; fi
    if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
fi

step "Compiling the DS4 objects with make (-j$JOBS)"
run make -C "$ROOT" "-j$JOBS" ${MAKE_OVERRIDES[@]+"${MAKE_OVERRIDES[@]}"} $OBJECTS

LINK_OBJECTS=()
for object in $OBJECTS; do
    [ -f "$ROOT/$object" ] || die "make did not produce $ROOT/$object"
    LINK_OBJECTS+=("$ROOT/$object")
done

step "Compiling the ZenCODE shim"
SHIM_OBJECT="$WORK/zencode_ds4_shim.o"
run "$CC_BIN" ${SHIM_CFLAGS[@]+"${SHIM_CFLAGS[@]}"} -I"$ROOT" -I"$SHIM_DIR" -c -o "$SHIM_OBJECT" "$SHIM_SOURCE"

step "Linking $OUT_NAME"
mkdir -p "$OUT_DIR"
TMP_OUT="$OUT_DIR/.$OUT_NAME.tmp.$$"
rm -f "$TMP_OUT"
case "$BACKEND" in
    metal|cpu)
        if [ "$HOST_OS" = "Darwin" ]; then
            run "$CC_BIN" -dynamiclib -o "$TMP_OUT" "$SHIM_OBJECT" "${LINK_OBJECTS[@]}" \
                "${LINK_LIBS[@]}" -install_name "@rpath/$OUT_NAME"
        else
            run "$CC_BIN" -shared -fPIC -o "$TMP_OUT" "$SHIM_OBJECT" "${LINK_OBJECTS[@]}" \
                "${LINK_LIBS[@]}"
        fi
        ;;
    cuda)
        run "$NVCC_BIN" "${LINK_FLAGS[@]}" -shared -o "$TMP_OUT" "$SHIM_OBJECT" "${LINK_OBJECTS[@]}" \
            "${LINK_LIBS[@]}"
        ;;
    rocm)
        run "$HIPCC_BIN" "${LINK_FLAGS[@]}" -shared -o "$TMP_OUT" "$SHIM_OBJECT" "${LINK_OBJECTS[@]}" \
            "${LINK_LIBS[@]}"
        ;;
esac
[ -s "$TMP_OUT" ] || die "the linker did not produce $TMP_OUT"

# ----------------------------------------------------------------------------
# Publish (atomic: temp file in the destination directory, then mv)
# ----------------------------------------------------------------------------

sha256_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -c1-64
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -c1-64
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | sed 's/^.*= *//'
    else
        die "no SHA-256 tool found (shasum, sha256sum or openssl)"
    fi
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Same inputs as ZenCODE: ds4.h of the root, then the shim source and the ABI header.
HASH="$(cat "$ROOT/ds4.h" "$SHIM_SOURCE" "$SHIM_ABI_HEADER" | sha256_stdin | cut -c1-16)"
ABI_VERSION="$(sed -n 's/^#define[[:space:]][[:space:]]*ZENCODE_DS4_ABI_VERSION[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SHIM_ABI_HEADER" | head -n 1)"
[ -n "$ABI_VERSION" ] || die "ZENCODE_DS4_ABI_VERSION not found in $SHIM_ABI_HEADER"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_JSON="$OUT_DIR/.build.json.tmp.$$"
{
    printf '{\n'
    printf '  "root": "%s",\n' "$(json_escape "$ROOT")"
    printf '  "backend": "%s",\n' "$BACKEND"
    if [ -n "$ARCH" ]; then
        printf '  "arch": "%s",\n' "$(json_escape "$ARCH")"
    else
        printf '  "arch": null,\n'
    fi
    printf '  "date": "%s",\n' "$BUILD_DATE"
    printf '  "hash": "%s",\n' "$HASH"
    printf '  "abiVersion": %s\n' "$ABI_VERSION"
    printf '}\n'
} > "$TMP_JSON"

step "Publishing $OUTPUT"
# A crash between the two moves leaves a library without build.json, which
# ZenCODE treats as stale and rebuilds.
rm -f "$OUT_JSON"
mv -f "$TMP_OUT" "$OUTPUT"
TMP_OUT=""
mv -f "$TMP_JSON" "$OUT_JSON"
TMP_JSON=""

step "Done: $OUTPUT (abi $ABI_VERSION, sources $HASH)"
