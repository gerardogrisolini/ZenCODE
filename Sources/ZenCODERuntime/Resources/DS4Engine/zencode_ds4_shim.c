/*
 * zencode_ds4_shim.c - ZenCODE in-process DS4 engine shim.
 *
 * Implements the ABI declared in zencode_ds4_abi.h on top of the public DS4
 * API (ds4.h) plus the helper modules ds4-agent uses (ds4_kvstore.h,
 * ds4_gpu_args.h, ds4_distributed.h, ds4_tp.h).  Behaviour mirrors
 * ds4_agent.c; the references below are to the checkout the shim was written
 * against (antirez/ds4 ee7e840).
 *
 * Build (performed by ZenCODE setup, not by SwiftPM)
 *   cc -std=c99 -fPIC -I<ds4> -c zencode_ds4_shim.c
 *   then link a shared library with the DS4 Makefile objects of the chosen
 *   backend plus ds4_kvstore.o and ds4_gpu_args.o:
 *   - Darwin/Metal: ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o
 *     ds4_metal.o ds4_layer_pack.o ds4_engram.o ds4_kvstore.o ds4_gpu_args.o
 *     -framework Foundation -framework Metal -lm -pthread
 *   - CPU (DS4_NO_GPU): ds4_cpu.o ds4_image.o ds4_distributed.o ds4_tp.o
 *     ds4_ssd.o ds4_layer_pack.o ds4_kvstore.o ds4_gpu_args_cpu.o -lm -pthread;
 *     compile this file with -DDS4_NO_GPU too (default backend = cpu).
 *   - CUDA: ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_cuda.o
 *     ds4_layer_pack.o ds4_engram.o $(MMQ_OBJS) ds4_kvstore.o ds4_gpu_args.o,
 *     linked with the CUDA libraries (-lcudart -lcublas).
 *   - ROCm: the ROCm CORE_OBJS (ds4_rocm*.o, $(ROCM_MMQ_OBJS)) built with
 *     -DDS4_ROCM_BUILD, linked through hipcc with $(ROCM_LDLIBS).
 *   On Linux every object must be position independent (-fPIC; the
 *   Makefile only adds it for ROCm host objects) and the Makefile adds
 *   -D_GNU_SOURCE (this file defines it itself when missing).
 *
 * Runtime files
 *   - Metal kernels: ds4_metal.m (ds4_gpu_full_source) concatenates 26
 *     sources listed as {DS4_METAL_<NAME>_SOURCE, "metal/<file>.metal"} and
 *     reads the override env var first, then the cwd-relative path.  Every
 *     entry follows NAME == UPPER(file stem) and metal/ holds exactly those
 *     26 files (no exceptions), so engine_open exports
 *     DS4_METAL_<UPPER(stem)>_SOURCE=<ds4_root>/metal/<stem>.metal for each
 *     <ds4_root>/metal/<stem>.metal with setenv(..., 0).  User overrides are kept;
 *     values previously exported by this shim for another root are replaced.
 *     A future source missing from metal/ makes DS4 fail with "Metal source
 *     ... not found", reported through the captured stderr.
 *   - CPU/CUDA/ROCm and image decoding open no cwd-relative files at runtime
 *     (checked: ds4.c, ds4_cuda.cu, ds4_image.c; images are compiled in from
 *     third_party/iris).  Remaining runtime paths are absolute or
 *     caller-provided: /proc/self/oom_score_adj (Linux), /tmp/ds4.lock or
 *     $DS4_LOCK_FILE, /tmp/ds4-session-payload.XXXXXX (payload staging),
 *     librdma.dylib / libibverbs.so.1 (dlopen by name, TP RDMA only).
 *     Model, MTP, vision and steering paths are passed verbatim: callers use
 *     absolute paths.
 *
 * Process-global effects
 *   - Instance lock: ds4_engine_open() calls ds4_acquire_instance_lock()
 *     (ds4.c), which exit(2)s when $DS4_LOCK_FILE (default /tmp/ds4.lock) is
 *     already flock()ed, including by an engine open in this process.  The
 *     shim performs the same open/flock first and returns
 *     ZENCODE_DS4_ERR_INSTANCE_LOCKED instead.  Residual race: another
 *     process may take the lock between the shim's unlock and DS4's flock;
 *     DS4 then still exits the process.
 *   - stderr: engine_open, session_create, set_power, set_directional_steering
 *     and kv save/load temporarily point fd 2 at a tmpfile() (dup/dup2,
 *     restored on every path) to turn DS4 diagnostics into error messages.
 *     Output of other threads during those calls is captured too.
 *   - setenv() of the Metal source variables is not synchronized with
 *     getenv() on other threads.
 *
 * Residual risks (DS4 code paths this shim cannot intercept)
 *   - ds4.c still exit(1)s on malformed or unsupported GGUF metadata/tensors
 *     (ds4_die, required_u32, tensor validation), on allocation failures
 *     (xmalloc/xcalloc) and ds4_kvstore.c on its own allocation failures.
 *     The shim pre-checks only what is cheap: model/mtp/vision GGUF files
 *     must open as regular files of at least 32 bytes (model_open() would
 *     exit(1) otherwise).
 *   - ds4_acquire_instance_lock registers atexit(ds4_release_instance_lock).
 *   - DS4 writes to stdout only from inspection/test helpers
 *     (model_summary, graph tests), which the shim never calls.
 *   - The TP leader / distributed coordinator paths replicate ds4-agent but
 *     cannot be exercised in ZenCODE's test environment.
 *
 * Threading: no internal locking.  Callers serialize every call (see the
 * header).  The global last-error buffer is thread-local.
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "zencode_ds4_abi.h"

#include "ds4.h"
#include "ds4_distributed.h"
#include "ds4_gpu_args.h"
#include "ds4_kvstore.h"
#include "ds4_tp.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------------
 * ABI constants must match ds4.h.
 * --------------------------------------------------------------------- */

_Static_assert(ZENCODE_DS4_THINK_NONE == (int)DS4_THINK_NONE, "think mode NONE mismatch");
_Static_assert(ZENCODE_DS4_THINK_HIGH == (int)DS4_THINK_HIGH, "think mode HIGH mismatch");
_Static_assert(ZENCODE_DS4_THINK_MAX == (int)DS4_THINK_MAX, "think mode MAX mismatch");
_Static_assert(ZENCODE_DS4_THINK_LOW == (int)DS4_THINK_LOW, "think mode LOW mismatch");
_Static_assert(ZENCODE_DS4_THINK_MEDIUM == (int)DS4_THINK_MEDIUM, "think mode MEDIUM mismatch");
_Static_assert(ZENCODE_DS4_THINK_LEVEL_BASE == DS4_THINK_LEVEL_BASE, "think level base mismatch");
_Static_assert(ZENCODE_DS4_SYNC_INTERRUPTED == DS4_SESSION_SYNC_INTERRUPTED,
               "sync interrupted code mismatch");

/* ------------------------------------------------------------------------
 * Types
 * --------------------------------------------------------------------- */

#define ZDS4_ERR_CAP 2048
#define ZDS4_DS4_ERR_CAP 512
#define ZDS4_LOG_CAP (256u * 1024u)
#define ZDS4_LOG_TAIL_LINES 4
#define ZDS4_SPEC_TOKENS 17 /* first token + up to 16 MTP drafts */

typedef struct {
    ds4_engine *engine;
    ds4_engine_options opt;
    char **owned;       /* strdup'd option values and extra_arg tokens */
    size_t owned_len;
    size_t owned_cap;
    char **argv;        /* extra_arg tokens; DS4 option parsers keep pointers */
    int argc;
    ds4_tp *tp_leader;
    int live_sessions;
    char last_error[ZDS4_ERR_CAP];
} zds4_engine;

typedef struct {
    ds4_tokens tokens;
    ds4_vision_span *spans; /* owns the embeddings */
    size_t span_count;
    size_t span_cap;
} zds4_tokens;

typedef struct {
    ds4_vision_embedding embedding;
} zds4_embedding;

typedef struct {
    zds4_engine *owner;
    ds4_session *session;
    ds4_tokens transcript;
    bool transcript_valid;
    bool synced_with_images;
    double stats[ZENCODE_DS4_STAT_COUNT];
    zencode_ds4_cancel_fn cancel;
    void *cancel_ud;
} zds4_session;

typedef struct {
    int saved_fd;
    FILE *tmp;
    bool active;
} zds4_capture;

/* ------------------------------------------------------------------------
 * Errors
 * --------------------------------------------------------------------- */

static __thread char g_last_error[ZDS4_ERR_CAP];
static char *g_open_log;
static char *g_metal_applied_dir;

static void zds4_clear_error(zds4_engine *ze) {
    g_last_error[0] = '\0';
    if (ze) ze->last_error[0] = '\0';
}

static int32_t zds4_fail(zds4_engine *ze, int32_t code, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static int32_t zds4_fail(zds4_engine *ze, int32_t code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, ap);
    va_end(ap);
    if (ze) snprintf(ze->last_error, sizeof(ze->last_error), "%s", g_last_error);
    return code;
}

static double zds4_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1.0e-9;
}

/* ------------------------------------------------------------------------
 * stderr capture
 * --------------------------------------------------------------------- */

static void zds4_capture_begin(zds4_capture *c) {
    c->saved_fd = -1;
    c->tmp = NULL;
    c->active = false;
    fflush(stderr);
    c->tmp = tmpfile();
    if (!c->tmp) return;
    c->saved_fd = dup(STDERR_FILENO);
    if (c->saved_fd < 0) {
        fclose(c->tmp);
        c->tmp = NULL;
        return;
    }
    (void)fcntl(c->saved_fd, F_SETFD, FD_CLOEXEC);
    if (dup2(fileno(c->tmp), STDERR_FILENO) < 0) {
        close(c->saved_fd);
        c->saved_fd = -1;
        fclose(c->tmp);
        c->tmp = NULL;
        return;
    }
    c->active = true;
}

/* Restores fd 2 and returns the captured text (tail capped at ZDS4_LOG_CAP),
 * or NULL when nothing was captured.  Always safe to call. */
static char *zds4_capture_end(zds4_capture *c) {
    if (!c->active) return NULL;
    fflush(stderr);
    while (dup2(c->saved_fd, STDERR_FILENO) < 0 && errno == EINTR) {
    }
    close(c->saved_fd);
    c->saved_fd = -1;
    c->active = false;

    char *text = NULL;
    const int fd = fileno(c->tmp);
    const off_t end = lseek(fd, 0, SEEK_END);
    if (end > 0) {
        const off_t start = end > (off_t)ZDS4_LOG_CAP ? end - (off_t)ZDS4_LOG_CAP : 0;
        const size_t want = (size_t)(end - start);
        text = malloc(want + 1);
        if (text) {
            size_t got = 0;
            while (got < want) {
                const ssize_t n = pread(fd, text + got, want - got, start + (off_t)got);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                got += (size_t)n;
            }
            text[got] = '\0';
        }
    }
    fclose(c->tmp);
    c->tmp = NULL;
    return text;
}

/* Copies the last non-empty lines of `log` into `out`, joined by " | ". */
static void zds4_log_tail(const char *log, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!log) return;
    const char *starts[ZDS4_LOG_TAIL_LINES];
    size_t lens[ZDS4_LOG_TAIL_LINES];
    int found = 0;
    const char *end = log + strlen(log);
    while (end > log && found < ZDS4_LOG_TAIL_LINES) {
        const char *line_end = end;
        const char *line_start = line_end;
        while (line_start > log && line_start[-1] != '\n') line_start--;
        const char *a = line_start;
        const char *b = line_end;
        while (a < b && isspace((unsigned char)*a)) a++;
        while (b > a && isspace((unsigned char)b[-1])) b--;
        if (b > a) {
            starts[found] = a;
            lens[found] = (size_t)(b - a);
            found++;
        }
        end = line_start > log ? line_start - 1 : log;
    }
    size_t used = 0;
    for (int i = found - 1; i >= 0; i--) {
        const int n = snprintf(out + used, cap - used, "%s%.*s",
                               used ? " | " : "", (int)lens[i], starts[i]);
        if (n < 0 || (size_t)n >= cap - used) break;
        used += (size_t)n;
    }
}

/* Builds "<message>: <stderr tail>" (or just the message). */
static int32_t zds4_fail_with_log(zds4_engine *ze, int32_t code, const char *message,
                                  const char *log) {
    char tail[1024];
    zds4_log_tail(log, tail, sizeof(tail));
    if (tail[0]) return zds4_fail(ze, code, "%s: %s", message, tail);
    return zds4_fail(ze, code, "%s", message);
}

/* ------------------------------------------------------------------------
 * Option parsing helpers
 * --------------------------------------------------------------------- */

static char *zds4_own_strdup(zds4_engine *ze, const char *s) {
    if (ze->owned_len == ze->owned_cap) {
        const size_t cap = ze->owned_cap ? ze->owned_cap * 2 : 32;
        char **grown = realloc(ze->owned, cap * sizeof(*grown));
        if (!grown) return NULL;
        ze->owned = grown;
        ze->owned_cap = cap;
    }
    const size_t len = strlen(s);
    char *copy = malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, s, len + 1);
    ze->owned[ze->owned_len++] = copy;
    return copy;
}

static bool zds4_parse_long(const char *s, long min, long max, long *out) {
    if (!s || !s[0]) return false;
    char *end = NULL;
    errno = 0;
    const long v = strtol(s, &end, 10);
    if (errno != 0 || !end || *end != '\0' || v < min || v > max) return false;
    *out = v;
    return true;
}

static bool zds4_parse_float(const char *s, float min, float max, float *out) {
    if (!s || !s[0]) return false;
    char *end = NULL;
    errno = 0;
    const float v = strtof(s, &end);
    if (errno == ERANGE || !end || *end != '\0' || !isfinite(v) || v < min || v > max)
        return false;
    *out = v;
    return true;
}

static bool zds4_parse_bool(const char *s, bool *out) {
    if (!s) return false;
    if (!strcmp(s, "1") || !strcmp(s, "true") || !strcmp(s, "yes")) {
        *out = true;
        return true;
    }
    if (!strcmp(s, "0") || !strcmp(s, "false") || !strcmp(s, "no")) {
        *out = false;
        return true;
    }
    return false;
}

static ds4_backend zds4_default_backend(void) {
#ifdef DS4_NO_GPU
    return DS4_BACKEND_CPU;
#elif defined(__APPLE__)
    return DS4_BACKEND_METAL;
#else
    return DS4_BACKEND_CUDA;
#endif
}

static bool zds4_valid_think_mode(int32_t mode) {
    return (mode >= ZENCODE_DS4_THINK_NONE && mode <= ZENCODE_DS4_THINK_MEDIUM) ||
           (mode >= ZENCODE_DS4_THINK_LEVEL_BASE &&
            mode <= ZENCODE_DS4_THINK_LEVEL_BASE + ZENCODE_DS4_THINK_LEVEL_MAX);
}

/* ------------------------------------------------------------------------
 * Metal sources and instance lock
 * --------------------------------------------------------------------- */

static char *zds4_join(const char *a, const char *b) {
    const size_t la = strlen(a);
    const size_t lb = strlen(b);
    const bool slash = la > 0 && a[la - 1] == '/';
    char *out = malloc(la + (slash ? 0 : 1) + lb + 1);
    if (!out) return NULL;
    memcpy(out, a, la);
    size_t pos = la;
    if (!slash) out[pos++] = '/';
    memcpy(out + pos, b, lb + 1);
    return out;
}

/* Exports DS4_METAL_<UPPER(stem)>_SOURCE for each <root>/metal/<stem>.metal.
 * `required` (Metal backend) turns a missing directory or an empty one into
 * an error. */
static int32_t zds4_configure_metal_sources(zds4_engine *ze, const char *root, bool required) {
    char *dir = zds4_join(root, "metal/");
    if (!dir) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    DIR *d = opendir(dir);
    if (!d) {
        const int saved = errno;
        int32_t rc = 0;
        if (required) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                           "ds4_root %s has no readable metal/ directory: %s",
                           root, strerror(saved));
        }
        free(dir);
        return rc;
    }

    int count = 0;
    int32_t rc = 0;
    const size_t prev_len = g_metal_applied_dir ? strlen(g_metal_applied_dir) : 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        const size_t len = strlen(name);
        const size_t ext = sizeof(".metal") - 1;
        if (len <= ext || strcmp(name + len - ext, ".metal") != 0) continue;
        const size_t stem_len = len - ext;
        char var[256];
        const size_t prefix_len = sizeof("DS4_METAL_") - 1;
        const size_t suffix_len = sizeof("_SOURCE") - 1;
        if (prefix_len + stem_len + suffix_len + 1 > sizeof(var)) continue;
        memcpy(var, "DS4_METAL_", prefix_len);
        for (size_t i = 0; i < stem_len; i++) {
            const unsigned char ch = (unsigned char)name[i];
            var[prefix_len + i] = isalnum(ch) ? (char)toupper(ch) : '_';
        }
        memcpy(var + prefix_len + stem_len, "_SOURCE", suffix_len + 1);

        char *path = zds4_join(dir, name);
        if (!path) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
            break;
        }
        const char *current = getenv(var);
        const bool ours = current && g_metal_applied_dir &&
                          strncmp(current, g_metal_applied_dir, prev_len) == 0;
        if (setenv(var, path, ours ? 1 : 0) != 0) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                           "failed to export %s: %s", var, strerror(errno));
            free(path);
            break;
        }
        free(path);
        count++;
    }
    closedir(d);

    if (rc == 0 && required && count == 0) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                       "ds4_root %s has no metal/*.metal sources", root);
    }
    if (rc == 0) {
        free(g_metal_applied_dir);
        g_metal_applied_dir = dir;
    } else {
        free(dir);
    }
    return rc;
}

/* model_open() (ds4.c) exit(1)s when a GGUF cannot be opened or is shorter
 * than 32 bytes: fail cleanly first. */
static int32_t zds4_check_gguf_file(const char *key, const char *path) {
    if (!path) return 0;
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s: cannot open '%s': %s",
                         key, path, strerror(errno));
    }
    struct stat st;
    int32_t rc = 0;
    if (fstat(fd, &st) != 0) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s: cannot stat '%s': %s",
                       key, path, strerror(errno));
    } else if (!S_ISREG(st.st_mode)) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s: '%s' is not a regular file",
                       key, path);
    } else if (st.st_size < 32) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION,
                       "%s: '%s' is too small to be a GGUF file", key, path);
    }
    close(fd);
    return rc;
}

/* Same open/flock as ds4_acquire_instance_lock(), which would exit(2). */
static int32_t zds4_check_instance_lock(zds4_engine *ze) {
    const char *path = getenv("DS4_LOCK_FILE");
    if (!path || !path[0]) path = "/tmp/ds4.lock";

    const int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "failed to open DS4 lock file %s: %s",
                         path, strerror(errno));
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        const int saved = errno;
        if (saved == EWOULDBLOCK) {
            char buf[64];
            const ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);
            long owner = -1;
            if (n > 0) {
                buf[n] = '\0';
                owner = strtol(buf, NULL, 10);
            }
            close(fd);
            if (owner > 0 && owner == (long)getpid()) {
                return zds4_fail(ze, ZENCODE_DS4_ERR_INSTANCE_LOCKED,
                                 "another ds4 process is already running (pid %ld): "
                                 "a DS4 engine is already open in this process", owner);
            }
            if (owner > 0) {
                return zds4_fail(ze, ZENCODE_DS4_ERR_INSTANCE_LOCKED,
                                 "another ds4 process is already running (pid %ld)", owner);
            }
            return zds4_fail(ze, ZENCODE_DS4_ERR_INSTANCE_LOCKED,
                             "another ds4 process is already running");
        }
        close(fd);
        return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "failed to lock %s: %s", path, strerror(saved));
    }
    (void)flock(fd, LOCK_UN);
    close(fd);
    return 0;
}

/* ------------------------------------------------------------------------
 * Library
 * --------------------------------------------------------------------- */

int32_t zencode_ds4_abi_version(void) {
    return ZENCODE_DS4_ABI_VERSION;
}

const char *zencode_ds4_last_error(void) {
    return g_last_error;
}

void zencode_ds4_string_free(char *s) {
    free(s);
}

const char *zencode_ds4_engine_open_log(void) {
    return g_open_log ? g_open_log : "";
}

int32_t zencode_ds4_think_mode_parse_level(const char *text) {
    zds4_clear_error(NULL);
    ds4_think_mode mode = DS4_THINK_NONE;
    if (!text || !ds4_think_mode_parse_level(text, &mode)) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "think level must be an integer from 0 to 100");
    }
    return (int32_t)mode;
}

int32_t zencode_ds4_think_mode_for_context(int32_t think_mode, int32_t ctx_size) {
    zds4_clear_error(NULL);
    if (!zds4_valid_think_mode(think_mode)) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "invalid think mode %d", (int)think_mode);
    }
    return (int32_t)ds4_think_mode_for_context((ds4_think_mode)think_mode, (int)ctx_size);
}

/* ------------------------------------------------------------------------
 * Engine
 * --------------------------------------------------------------------- */

static void zds4_engine_destroy(zds4_engine *ze) {
    if (!ze) return;
    for (size_t i = 0; i < ze->owned_len; i++) free(ze->owned[i]);
    free(ze->owned);
    free(ze->argv);
    free(ze);
}

static void zds4_store_open_log(char *log) {
    free(g_open_log);
    g_open_log = log;
}

static bool zds4_seen_key(const char **seen, size_t n, const char *key) {
    for (size_t i = 0; i < n; i++) {
        if (!strcmp(seen[i], key)) return true;
    }
    return false;
}

/* Applies one "key=value" option.  `value` is owned by the engine. */
static int32_t zds4_apply_option(zds4_engine *ze, const char *key, char *value,
                                 const char **ds4_root, bool *steering_scale_set) {
    ds4_engine_options *o = &ze->opt;
    long iv = 0;
    float fv = 0.0f;
    bool bv = false;
#define ZDS4_BAD_VALUE() \
    zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION, "invalid value for %s: '%s'", key, value)

    if (!strcmp(key, "ds4_root")) {
        if (value[0] != '/') {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                             "ds4_root must be an absolute path: '%s'", value);
        }
        struct stat st;
        if (stat(value, &st) != 0 || !S_ISDIR(st.st_mode)) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                             "ds4_root is not a directory: '%s'", value);
        }
        *ds4_root = value;
    } else if (!strcmp(key, "model_path")) {
        if (!value[0]) return ZDS4_BAD_VALUE();
        o->model_path = value;
    } else if (!strcmp(key, "mtp_path")) {
        if (!value[0]) return ZDS4_BAD_VALUE();
        o->mtp_path = value;
    } else if (!strcmp(key, "vision_path")) {
        if (!value[0]) return ZDS4_BAD_VALUE();
        o->vision_path = value;
    } else if (!strcmp(key, "backend")) {
        if (!strcmp(value, "metal")) o->backend = DS4_BACKEND_METAL;
        else if (!strcmp(value, "cuda") || !strcmp(value, "rocm")) o->backend = DS4_BACKEND_CUDA;
        else if (!strcmp(value, "cpu")) o->backend = DS4_BACKEND_CPU;
        else {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                             "invalid backend '%s' (valid: metal, cuda, rocm, cpu)", value);
        }
    } else if (!strcmp(key, "n_threads")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->n_threads = (int)iv;
    } else if (!strcmp(key, "context_size")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->context_size = (int)iv;
        o->placement_ctx_hint = (int)iv;
    } else if (!strcmp(key, "session_count")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->placement_session_count_hint = (int)iv;
    } else if (!strcmp(key, "prefill_chunk")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->prefill_chunk = (uint32_t)iv;
    } else if (!strcmp(key, "mtp_draft_tokens")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->mtp_draft_tokens = (int)iv;
    } else if (!strcmp(key, "mtp_margin")) {
        if (!zds4_parse_float(value, 0.0f, 1000.0f, &fv)) return ZDS4_BAD_VALUE();
        o->mtp_margin = fv;
    } else if (!strcmp(key, "glm_mtp")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->glm_mtp = bv;
    } else if (!strcmp(key, "dspark")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->dspark = bv;
    } else if (!strcmp(key, "dspark_strict")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->dspark_strict = bv;
        if (bv) o->dspark = true;
    } else if (!strcmp(key, "dspark_exact_sampling")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->dspark_exact_sampling = bv;
    } else if (!strcmp(key, "dspark_confidence_threshold")) {
        if (!zds4_parse_float(value, 0.0f, 1.0f, &fv)) return ZDS4_BAD_VALUE();
        o->dspark = true;
        o->dspark_confidence_threshold = fv;
        o->dspark_confidence_threshold_set = true;
    } else if (!strcmp(key, "power_percent")) {
        if (!zds4_parse_long(value, 1, 100, &iv)) return ZDS4_BAD_VALUE();
        o->power_percent = (int)iv;
    } else if (!strcmp(key, "quality")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->quality = bv;
    } else if (!strcmp(key, "warm_weights")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->warm_weights = bv;
    } else if (!strcmp(key, "ssd_streaming")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->ssd_streaming = bv;
    } else if (!strcmp(key, "ssd_streaming_cold")) {
        if (!zds4_parse_bool(value, &bv)) return ZDS4_BAD_VALUE();
        o->ssd_streaming_cold = bv;
    } else if (!strcmp(key, "ssd_streaming_cache_experts")) {
        uint32_t experts = 0;
        uint64_t bytes = 0;
        if (!ds4_parse_streaming_cache_experts_arg(value, &experts, &bytes)) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                             "invalid value for %s: '%s' (positive count or <number>GB)",
                             key, value);
        }
        o->ssd_streaming_cache_experts = experts;
        o->ssd_streaming_cache_bytes = bytes;
    } else if (!strcmp(key, "ssd_streaming_full_layers")) {
        if (!zds4_parse_long(value, 0, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->ssd_streaming_full_layers = (uint32_t)iv;
        o->ssd_streaming_full_layers_set = true;
    } else if (!strcmp(key, "ssd_streaming_preload_experts")) {
        if (!zds4_parse_long(value, 1, INT32_MAX, &iv)) return ZDS4_BAD_VALUE();
        o->ssd_streaming_preload_experts = (uint32_t)iv;
    } else if (!strcmp(key, "directional_steering_file")) {
        if (!value[0]) return ZDS4_BAD_VALUE();
        o->directional_steering_file = value;
    } else if (!strcmp(key, "directional_steering_ffn")) {
        if (!zds4_parse_float(value, -100.0f, 100.0f, &fv)) return ZDS4_BAD_VALUE();
        o->directional_steering_ffn = fv;
        *steering_scale_set = true;
    } else if (!strcmp(key, "directional_steering_attn")) {
        if (!zds4_parse_float(value, -100.0f, 100.0f, &fv)) return ZDS4_BAD_VALUE();
        o->directional_steering_attn = fv;
        *steering_scale_set = true;
    } else if (!strcmp(key, "extra_arg")) {
        char **grown = realloc(ze->argv, (size_t)(ze->argc + 2) * sizeof(*grown));
        if (!grown) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
        ze->argv = grown;
        ze->argv[ze->argc++] = value;
        ze->argv[ze->argc] = NULL;
    } else {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION, "unknown engine option '%s'", key);
    }
#undef ZDS4_BAD_VALUE
    return 0;
}

/* Parses the opaque extra_arg argv like ds4-agent parse_options. */
static int32_t zds4_parse_extra_args(zds4_engine *ze, const char **gpu_vram,
                                     const char **gpu_devices) {
    for (int i = 0; i < ze->argc; i++) {
        const char *arg = ze->argv[i];
        char perr[256] = {0};
        const ds4_dist_cli_parse_result dist =
            ds4_dist_parse_cli_arg(arg, &i, ze->argc, ze->argv, &ze->opt.distributed,
                                   perr, sizeof(perr));
        if (dist == DS4_DIST_CLI_ERROR) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION, "extra_arg: %s",
                             perr[0] ? perr : "invalid distributed option");
        }
        if (dist == DS4_DIST_CLI_MATCHED) continue;

        memset(perr, 0, sizeof(perr));
        const int tp = ds4_tp_parse_cli_arg(arg, &i, ze->argc, ze->argv, &ze->opt.tp,
                                            perr, sizeof(perr));
        if (tp == DS4_TP_CLI_ERROR) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION, "extra_arg: %s",
                             perr[0] ? perr : "invalid tensor-parallel option");
        }
        if (tp == DS4_TP_CLI_MATCHED) continue;

        if (!strcmp(arg, "--gpu-vram") || !strcmp(arg, "--gpu-devices")) {
            if (i + 1 >= ze->argc) {
                return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                                 "extra_arg: missing value for %s", arg);
            }
            if (!strcmp(arg, "--gpu-vram")) *gpu_vram = ze->argv[++i];
            else *gpu_devices = ze->argv[++i];
        } else if (!strcmp(arg, "--cuda-tensor-parallel")) {
            ze->opt.cuda_tensor_parallel = true;
        } else {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                             "extra_arg: unknown option '%s'", arg);
        }
    }
    return 0;
}

/* ds4-agent main(): TP leader bring-up after the engine is open. */
static int32_t zds4_start_tp_leader(zds4_engine *ze) {
    if (ze->opt.tp.role != DS4_TP_LEADER) return 0;
    if (ze->opt.context_size <= 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_OPTION,
                         "a tensor-parallel leader requires context_size");
    }
    ds4_engine *e = ze->engine;
    char tp_err[256] = "";
    ds4_tp_identity id;
    memset(&id, 0, sizeof(id));
    id.gguf_bytes = ds4_engine_model_bytes(e);
    id.model_id = (uint32_t)ds4_engine_model_id(e);
    id.n_layer = (uint32_t)ds4_engine_layer_count(e);
    id.n_embd = (uint32_t)ds4_engine_embd_dim(e);
    id.n_vocab = (uint32_t)ds4_engine_vocab_size(e);
    id.quant_bits = (uint32_t)ds4_engine_routed_quant_bits(e);
    id.ctx_size = (uint32_t)ze->opt.context_size;
    ds4_engine_tp_gate_schedule(e, &id.gate_slot_start, &id.gate_slot_step,
                                &id.gates_per_token, id.gate_slot_mask);
    ds4_tp *tp = NULL;
    if (!ds4_tp_create(&tp, &ze->opt.tp, &id, tp_err, sizeof(tp_err)) ||
        !ds4_engine_tp_bind(e, tp, tp_err, sizeof(tp_err))) {
        ds4_tp_free(tp);
        return zds4_fail(ze, ZENCODE_DS4_ERR_TENSOR_PARALLEL, "tensor parallelism: %s",
                         tp_err[0] ? tp_err : "leader bring-up failed");
    }
    ze->tp_leader = tp;
    return 0;
}

int32_t zencode_ds4_engine_open(const char *const *kv, size_t kv_count, void **out_engine) {
    zds4_clear_error(NULL);
    if (!out_engine) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "out_engine is NULL");
    }
    *out_engine = NULL;
    zds4_store_open_log(NULL);
    if (kv_count > 0 && !kv) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "kv is NULL");
    }

    zds4_engine *ze = calloc(1, sizeof(*ze));
    if (!ze) return zds4_fail(NULL, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    ze->opt.backend = zds4_default_backend();
    ze->opt.mtp_draft_tokens = 1;
    ze->opt.mtp_margin = 3.0f;

    const char *ds4_root = NULL;
    bool steering_scale_set = false;
    const char **seen = kv_count ? calloc(kv_count, sizeof(*seen)) : NULL;
    size_t seen_len = 0;
    int32_t rc = 0;
    if (kv_count && !seen) rc = zds4_fail(NULL, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");

    for (size_t i = 0; rc == 0 && i < kv_count; i++) {
        const char *entry = kv[i];
        if (!entry) {
            rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "engine option %zu is NULL", i);
            break;
        }
        const char *eq = strchr(entry, '=');
        if (!eq || eq == entry) {
            rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION,
                           "invalid engine option '%s' (expected key=value)", entry);
            break;
        }
        char *key = zds4_own_strdup(ze, entry);
        if (!key) {
            rc = zds4_fail(NULL, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
            break;
        }
        key[eq - entry] = '\0';
        char *value = key + (eq - entry) + 1;
        if (strcmp(key, "extra_arg") != 0) {
            if (zds4_seen_key(seen, seen_len, key)) {
                rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION,
                               "duplicate engine option '%s'", key);
                break;
            }
            seen[seen_len++] = key;
        }
        rc = zds4_apply_option(ze, key, value, &ds4_root, &steering_scale_set);
    }
    free(seen);

    const char *gpu_vram = NULL;
    const char *gpu_devices = NULL;
    if (rc == 0 && (!ze->opt.model_path || !ze->opt.model_path[0])) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "model_path is required");
    }
    if (rc == 0) rc = zds4_parse_extra_args(ze, &gpu_vram, &gpu_devices);

    /* ds4-agent parse_options post-processing. */
    char perr[256] = {0};
    if (rc == 0 && ze->opt.directional_steering_file && !steering_scale_set)
        ze->opt.directional_steering_ffn = 1.0f;
    if (rc == 0 && !ds4_tp_adopt_distributed_options(&ze->opt.tp, &ze->opt.distributed,
                                                     perr, sizeof(perr))) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s",
                       perr[0] ? perr : "invalid tensor-parallel options");
    }
    if (rc == 0 && ds4_dist_prepare_engine_options(&ze->opt.distributed, &ze->opt,
                                                   perr, sizeof(perr)) != 0) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s",
                       perr[0] ? perr : "invalid distributed options");
    }
    if (rc == 0 && !ds4_tp_validate_engine_options(&ze->opt, perr, sizeof(perr))) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s",
                       perr[0] ? perr : "invalid tensor-parallel options");
    }
    if (rc == 0 && (ze->opt.distributed.role == DS4_DISTRIBUTED_WORKER ||
                    ze->opt.tp.role == DS4_TP_WORKER)) {
        rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION,
                       "--role worker is a serving mode; start workers with ./ds4");
    }

    /* ds4-agent main(): multi-GPU placement selects the backend. */
    ds4_gpu_config gpu_cfg;
    memset(&gpu_cfg, 0, sizeof(gpu_cfg));
    bool use_gpu_cfg = false;
    bool skip_cuda = false;
    if (rc == 0 && (gpu_vram || gpu_devices)) {
        ze->opt.backend = gpu_vram && !strcmp(gpu_vram, "0") ? DS4_BACKEND_CPU : DS4_BACKEND_CUDA;
        char gpu_err[256] = {0};
        if (parse_gpu_vram_arg(gpu_vram, gpu_devices, &gpu_cfg, &skip_cuda,
                               gpu_err, sizeof(gpu_err)) != 0) {
            rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_OPTION, "%s",
                           gpu_err[0] ? gpu_err : "invalid --gpu-vram/--gpu-devices");
        } else if (skip_cuda) {
            ze->opt.backend = DS4_BACKEND_CPU;
        } else {
            ze->opt.backend = DS4_BACKEND_CUDA;
            use_gpu_cfg = true;
        }
    }

    if (rc == 0) rc = zds4_check_gguf_file("model_path", ze->opt.model_path);
    if (rc == 0) rc = zds4_check_gguf_file("mtp_path", ze->opt.mtp_path);
    if (rc == 0) rc = zds4_check_gguf_file("vision_path", ze->opt.vision_path);
    if (rc == 0 && ds4_root) {
        rc = zds4_configure_metal_sources(NULL, ds4_root, ze->opt.backend == DS4_BACKEND_METAL);
    }
    if (rc == 0) rc = zds4_check_instance_lock(NULL);
    if (rc != 0) {
        zds4_engine_destroy(ze);
        return rc;
    }

    zds4_capture cap;
    zds4_capture_begin(&cap);
    int open_rc;
    if (use_gpu_cfg) {
        const bool was_auto = (gpu_vram && !strcmp(gpu_vram, "auto")) || (!gpu_vram && gpu_devices);
        char layout[256];
        if (format_gpu_layout_line(&gpu_cfg, was_auto, layout, sizeof(layout)) > 0) {
            fprintf(stderr, "%s\n", layout);
        }
        open_rc = ds4_engine_create_with_gpu_config(&ze->engine, &ze->opt, &gpu_cfg);
    } else {
        open_rc = ds4_engine_open(&ze->engine, &ze->opt);
    }
    if (open_rc != 0 || !ze->engine) {
        char *log = zds4_capture_end(&cap);
        rc = zds4_fail_with_log(NULL, ZENCODE_DS4_ERR_ENGINE_OPEN, "ds4_engine_open failed", log);
        zds4_store_open_log(log);
        if (ze->engine) ds4_engine_close(ze->engine);
        ze->engine = NULL;
        zds4_engine_destroy(ze);
        return rc;
    }

    rc = zds4_start_tp_leader(ze);
    char *log = zds4_capture_end(&cap);
    if (rc != 0) {
        char message[ZDS4_ERR_CAP];
        snprintf(message, sizeof(message), "%s", g_last_error);
        rc = zds4_fail_with_log(NULL, rc, message, log);
        zds4_store_open_log(log);
        ds4_engine_close(ze->engine);
        ze->engine = NULL;
        zds4_engine_destroy(ze);
        return rc;
    }
    zds4_store_open_log(log);
    *out_engine = ze;
    return 0;
}

int32_t zencode_ds4_engine_close(void *engine) {
    zds4_clear_error(NULL);
    zds4_engine *ze = engine;
    if (!ze) return 0;
    ze->last_error[0] = '\0';
    if (ze->live_sessions > 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_BUSY,
                         "engine has %d live session(s); free them before closing",
                         ze->live_sessions);
    }
    if (ze->tp_leader) ds4_tp_send_stop(ze->tp_leader);
    if (ze->engine) ds4_engine_close(ze->engine);
    if (ze->tp_leader) ds4_tp_free(ze->tp_leader);
    ze->engine = NULL;
    ze->tp_leader = NULL;
    zds4_engine_destroy(ze);
    return 0;
}

const char *zencode_ds4_engine_last_error(void *engine) {
    zds4_engine *ze = engine;
    return ze ? ze->last_error : g_last_error;
}

/* Validates an engine handle and clears both error buffers. */
static zds4_engine *zds4_engine_arg(void *engine, int32_t *rc) {
    zds4_engine *ze = engine;
    zds4_clear_error(ze);
    if (!ze || !ze->engine) {
        *rc = zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "engine is NULL or closed");
        return NULL;
    }
    *rc = 0;
    return ze;
}

const char *zencode_ds4_engine_model_name(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return "";
    const char *name = ds4_engine_model_name(ze->engine);
    return name ? name : "";
}

int32_t zencode_ds4_engine_model_id(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return rc;
    return (int32_t)ds4_engine_model_id(ze->engine);
}

int32_t zencode_ds4_engine_routed_quant_bits(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return rc;
    return (int32_t)ds4_engine_routed_quant_bits(ze->engine);
}

int32_t zencode_ds4_engine_has_vision(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return rc;
    return ds4_engine_has_vision(ze->engine) ? 1 : 0;
}

int32_t zencode_ds4_engine_tool_syntax(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return rc;
    /* agent_tool_syntax_for_engine (ds4_agent.c). */
    if (ds4_engine_is_qwen4(ze->engine)) return ZENCODE_DS4_TOOL_SYNTAX_QWEN;
    if (ds4_engine_is_glm_dsa(ze->engine)) return ZENCODE_DS4_TOOL_SYNTAX_GLM;
    if (ds4_engine_is_deepseek41(ze->engine)) return ZENCODE_DS4_TOOL_SYNTAX_DSML41;
    return ZENCODE_DS4_TOOL_SYNTAX_DSML;
}

int32_t zencode_ds4_engine_mtp_draft_tokens(void *engine) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return rc;
    return (int32_t)ds4_engine_mtp_draft_tokens(ze->engine);
}

/* ------------------------------------------------------------------------
 * Token buffers
 * --------------------------------------------------------------------- */

static void zds4_tokens_destroy(zds4_tokens *t) {
    if (!t) return;
    for (size_t i = 0; i < t->span_count; i++) ds4_vision_embedding_free(&t->spans[i].embedding);
    free(t->spans);
    ds4_tokens_free(&t->tokens);
    free(t);
}

static int32_t zds4_tokens_arg(zds4_engine *ze, void *tokens, zds4_tokens **out) {
    *out = tokens;
    if (!tokens) return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "tokens is NULL");
    return 0;
}

void *zencode_ds4_tokens_new(void) {
    zds4_clear_error(NULL);
    zds4_tokens *t = calloc(1, sizeof(*t));
    if (!t) zds4_fail(NULL, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    return t;
}

void zencode_ds4_tokens_free(void *tokens) {
    zds4_tokens_destroy(tokens);
}

int32_t zencode_ds4_tokens_len(void *tokens) {
    zds4_clear_error(NULL);
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_tokens_arg(NULL, tokens, &t);
    if (rc != 0) return rc;
    return (int32_t)t->tokens.len;
}

int32_t zencode_ds4_tokens_get(void *tokens, int32_t index) {
    zds4_clear_error(NULL);
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_tokens_arg(NULL, tokens, &t);
    if (rc != 0) return rc;
    if (index < 0 || index >= t->tokens.len) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "token index %d out of range (len %d)", (int)index, t->tokens.len);
    }
    return (int32_t)t->tokens.v[index];
}

int32_t zencode_ds4_tokens_image_count(void *tokens) {
    zds4_clear_error(NULL);
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_tokens_arg(NULL, tokens, &t);
    if (rc != 0) return rc;
    return (int32_t)t->span_count;
}

void *zencode_ds4_tokens_copy(void *src) {
    zds4_clear_error(NULL);
    zds4_tokens *s = NULL;
    if (zds4_tokens_arg(NULL, src, &s) != 0) return NULL;
    if (s->span_count > 0) {
        zds4_fail(NULL, ZENCODE_DS4_ERR_UNSUPPORTED,
                  "token buffers holding images cannot be copied");
        return NULL;
    }
    zds4_tokens *t = calloc(1, sizeof(*t));
    if (!t) {
        zds4_fail(NULL, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
        return NULL;
    }
    ds4_tokens_copy(&t->tokens, &s->tokens);
    return t;
}

int32_t zencode_ds4_tokens_push(void *tokens, int32_t token) {
    zds4_clear_error(NULL);
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_tokens_arg(NULL, tokens, &t);
    if (rc != 0) return rc;
    if (token < 0) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "token id %d is negative",
                         (int)token);
    }
    ds4_tokens_push(&t->tokens, (int)token);
    return 0;
}

/* Common validation for engine + token buffer calls. */
static int32_t zds4_engine_tokens_args(void *engine, void *tokens, zds4_engine **ze,
                                       zds4_tokens **t) {
    int32_t rc = 0;
    *ze = zds4_engine_arg(engine, &rc);
    if (!*ze) return rc;
    return zds4_tokens_arg(*ze, tokens, t);
}

static int32_t zds4_check_think_mode(zds4_engine *ze, int32_t think_mode) {
    if (!zds4_valid_think_mode(think_mode)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "invalid think mode %d",
                         (int)think_mode);
    }
    if (ds4_think_mode_level((ds4_think_mode)think_mode) >= 0 &&
        !ds4_engine_is_deepseek41(ze->engine)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_UNSUPPORTED,
                         "explicit think levels require a DeepSeek V4.1 model");
    }
    return 0;
}

int32_t zencode_ds4_chat_begin(void *engine, void *tokens) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    ds4_chat_begin(ze->engine, &t->tokens);
    return 0;
}

int32_t zencode_ds4_chat_append_message(void *engine, void *tokens, const char *role,
                                        const char *content) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    if (!role || !role[0]) return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "role is empty");
    ds4_chat_append_message(ze->engine, &t->tokens, role, content ? content : "");
    return 0;
}

int32_t zencode_ds4_chat_append_think_prefix(void *engine, void *tokens, int32_t think_mode) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    rc = zds4_check_think_mode(ze, think_mode);
    if (rc != 0) return rc;
    ds4_chat_append_think_prefix(ze->engine, &t->tokens, (ds4_think_mode)think_mode);
    return 0;
}

int32_t zencode_ds4_chat_append_assistant_prefix(void *engine, void *tokens, int32_t think_mode) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    rc = zds4_check_think_mode(ze, think_mode);
    if (rc != 0) return rc;
    ds4_chat_append_assistant_prefix(ze->engine, &t->tokens, (ds4_think_mode)think_mode);
    return 0;
}

int32_t zencode_ds4_tokenize_rendered_chat(void *engine, void *tokens, const char *text) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    if (!text) return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "text is NULL");
    ds4_tokenize_rendered_chat(ze->engine, text, &t->tokens);
    return 0;
}

int32_t zencode_ds4_tokens_push_eos(void *engine, void *tokens) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    ds4_tokens_push(&t->tokens, ds4_token_eos(ze->engine));
    return 0;
}

char *zencode_ds4_render_tokens_text(void *engine, void *tokens, size_t *out_len) {
    if (out_len) *out_len = 0;
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    if (zds4_engine_tokens_args(engine, tokens, &ze, &t) != 0) return NULL;
    size_t len = 0;
    char *text = ds4_kvstore_render_tokens_text(ze->engine, &t->tokens, &len);
    if (!text) {
        zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "failed to render tokens");
        return NULL;
    }
    if (out_len) *out_len = len;
    return text;
}

/* ------------------------------------------------------------------------
 * Vision
 * --------------------------------------------------------------------- */

void *zencode_ds4_engine_vision_encode_file(void *engine, const char *path) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (!ze) return NULL;
    if (!path || !path[0]) {
        zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "image path is empty");
        return NULL;
    }
    if (!ds4_engine_has_vision(ze->engine)) {
        zds4_fail(ze, ZENCODE_DS4_ERR_UNSUPPORTED,
                  "the loaded model has no vision projector (vision_path)");
        return NULL;
    }
    zds4_embedding *h = calloc(1, sizeof(*h));
    if (!h) {
        zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
        return NULL;
    }
    char err[ZDS4_DS4_ERR_CAP] = {0};
    if (!ds4_engine_vision_encode_file(ze->engine, path, &h->embedding, err, sizeof(err))) {
        ds4_vision_embedding_free(&h->embedding);
        free(h);
        zds4_fail(ze, ZENCODE_DS4_ERR_VISION, "%s: %s", path,
                  err[0] ? err : "image encoding failed");
        return NULL;
    }
    return h;
}

void zencode_ds4_vision_embedding_free(void *embedding) {
    zds4_embedding *h = embedding;
    if (!h) return;
    ds4_vision_embedding_free(&h->embedding);
    free(h);
}

int32_t zencode_ds4_chat_append_multimodal_message(void *engine, void *tokens, const char *role,
                                                   const char *const *text_parts, size_t n_parts,
                                                   void *const *embeddings, size_t n_images) {
    zds4_engine *ze = NULL;
    zds4_tokens *t = NULL;
    const int32_t rc = zds4_engine_tokens_args(engine, tokens, &ze, &t);
    if (rc != 0) return rc;
    if (!role || !text_parts || n_parts != n_images + 1 || (n_images > 0 && !embeddings)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "multimodal message needs a role, n_images + 1 text parts and "
                         "n_images embeddings");
    }
    for (size_t i = 0; i < n_images; i++) {
        const zds4_embedding *h = embeddings[i];
        if (!h || !h->embedding.data || h->embedding.token_count == 0) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                             "image embedding %zu is NULL or already appended", i);
        }
    }
    if (n_images > 0 && !ds4_engine_has_vision(ze->engine)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_UNSUPPORTED,
                         "the loaded model has no vision projector (vision_path)");
    }

    if (t->span_count + n_images > t->span_cap) {
        size_t cap = t->span_cap ? t->span_cap : 4;
        while (cap < t->span_count + n_images) cap *= 2;
        ds4_vision_span *grown = realloc(t->spans, cap * sizeof(*grown));
        if (!grown) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
        t->spans = grown;
        t->span_cap = cap;
    }
    const char **parts = calloc(n_parts, sizeof(*parts));
    ds4_vision_embedding *embs = n_images ? calloc(n_images, sizeof(*embs)) : NULL;
    if (!parts || (n_images && !embs)) {
        free(parts);
        free(embs);
        return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    }
    for (size_t i = 0; i < n_parts; i++) parts[i] = text_parts[i] ? text_parts[i] : "";
    for (size_t i = 0; i < n_images; i++) {
        embs[i] = ((const zds4_embedding *)embeddings[i])->embedding;
    }
    ds4_vision_span *spans = n_images ? &t->spans[t->span_count] : NULL;
    if (spans) memset(spans, 0, n_images * sizeof(*spans));

    char err[ZDS4_DS4_ERR_CAP] = {0};
    const int ok = ds4_chat_append_multimodal_message(ze->engine, &t->tokens, role, parts, embs,
                                                      n_images, spans, err, sizeof(err));
    int32_t out = 0;
    if (ok) {
        /* DS4 moved each embedding into its span (and cleared the copy). */
        for (size_t i = 0; i < n_images; i++) {
            if (!embs[i].data) {
                zds4_embedding *h = embeddings[i];
                memset(&h->embedding, 0, sizeof(h->embedding));
            }
        }
        t->span_count += n_images;
    } else {
        /* On failure DS4 restores the embeddings; the handles still own them. */
        out = zds4_fail(ze, ZENCODE_DS4_ERR_VISION, "%s",
                        err[0] ? err : "failed to append multimodal message");
    }
    free(parts);
    free(embs);
    return out;
}

/* ------------------------------------------------------------------------
 * Sessions
 * --------------------------------------------------------------------- */

static int32_t zds4_session_arg(void *session, zds4_session **out) {
    zds4_session *s = session;
    *out = s;
    zds4_clear_error(s ? s->owner : NULL);
    if (!s || !s->session) {
        return zds4_fail(NULL, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "session is NULL");
    }
    return 0;
}

static bool zds4_cancel_trampoline(void *ud) {
    zds4_session *s = ud;
    return s && s->cancel && s->cancel(s->cancel_ud) != 0;
}

static void zds4_reset_stats(zds4_session *s) {
    for (int i = 0; i < ZENCODE_DS4_STAT_COUNT; i++) s->stats[i] = 0.0;
}

int32_t zencode_ds4_session_create(void *engine, int32_t ctx_size, void **out_session) {
    int32_t rc = 0;
    zds4_engine *ze = zds4_engine_arg(engine, &rc);
    if (out_session) *out_session = NULL;
    if (!ze) return rc;
    if (!out_session) return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "out_session is NULL");
    if (ctx_size <= 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "invalid context size %d",
                         (int)ctx_size);
    }
    zds4_session *s = calloc(1, sizeof(*s));
    if (!s) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");

    zds4_capture cap;
    zds4_capture_begin(&cap);
    const int create_rc = ds4_session_create(&s->session, ze->engine, (int)ctx_size);
    char *log = zds4_capture_end(&cap);
    if (create_rc != 0 || !s->session) {
        rc = zds4_fail_with_log(ze, ZENCODE_DS4_ERR_SESSION, "ds4_session_create failed", log);
        free(log);
        if (s->session) ds4_session_free(s->session);
        free(s);
        return rc;
    }
    free(log);
    s->owner = ze;
    zds4_reset_stats(s);
    ze->live_sessions++;
    *out_session = s;
    return 0;
}

void zencode_ds4_session_free(void *session) {
    zds4_session *s = session;
    if (!s) return;
    if (s->session) ds4_session_free(s->session);
    ds4_tokens_free(&s->transcript);
    if (s->owner && s->owner->live_sessions > 0) s->owner->live_sessions--;
    free(s);
}

static int32_t zds4_wait_route(zds4_session *s, zencode_ds4_progress_fn progress,
                               zencode_ds4_cancel_fn cancel, void *ud) {
    if (s->owner->opt.distributed.role != DS4_DISTRIBUTED_COORDINATOR) return 0;
    const struct timespec delay = {0, 250000000L};
    for (int ticks = 0;; ticks++) {
        char err[ZDS4_DS4_ERR_CAP] = {0};
        const int ready = ds4_session_distributed_route_ready(s->session, err, sizeof(err));
        if (ready > 0) return 0;
        if (ready < 0) {
            return zds4_fail(s->owner, ZENCODE_DS4_ERR_SESSION, "distributed route: %s",
                             err[0] ? err : "route error");
        }
        if (cancel && cancel(ud) != 0) {
            zds4_fail(s->owner, ZENCODE_DS4_SYNC_INTERRUPTED,
                      "cancelled while waiting for distributed route: %s",
                      err[0] ? err : "route incomplete");
            return ZENCODE_DS4_SYNC_INTERRUPTED;
        }
        if (progress && ticks % 20 == 0) progress(ud, "distributed_route_wait", ticks, 0);
        nanosleep(&delay, NULL);
    }
}

int32_t zencode_ds4_session_wait_distributed_route(void *session, zencode_ds4_progress_fn progress,
                                                   zencode_ds4_cancel_fn cancel, void *ud) {
    zds4_session *s = NULL;
    const int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    return zds4_wait_route(s, progress, cancel, ud);
}

/* Replaces the transcript with a copy of `tokens`. */
static void zds4_set_transcript(zds4_session *s, const ds4_tokens *tokens) {
    s->transcript.len = 0;
    for (int i = 0; i < tokens->len; i++) ds4_tokens_push(&s->transcript, tokens->v[i]);
    s->transcript_valid = true;
}

int32_t zencode_ds4_session_sync(void *session, void *tokens, zencode_ds4_progress_fn progress,
                                 zencode_ds4_cancel_fn cancel, void *ud, int32_t *out_cached,
                                 int32_t *out_suffix) {
    if (out_cached) *out_cached = 0;
    if (out_suffix) *out_suffix = 0;
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    zds4_tokens *t = NULL;
    rc = zds4_tokens_arg(s->owner, tokens, &t);
    if (rc != 0) return rc;
    if (t->tokens.len <= 0) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "prompt has no tokens");
    }

    rc = zds4_wait_route(s, progress, cancel, ud);
    if (rc != 0) return rc;

    /* agent_worker_sync_tokens (ds4_agent.c). */
    ds4_session *ss = s->session;
    const int old_pos = ds4_session_pos(ss);
    const int common = ds4_session_common_prefix(ss, &t->tokens);
    const int cached = common == old_pos && t->tokens.len >= old_pos ? common : 0;
    int suffix = t->tokens.len - cached;
    if (suffix < 0) suffix = t->tokens.len;
    if (out_cached) *out_cached = cached;
    if (out_suffix) *out_suffix = suffix;

    /* DS4's own progress events do not report where the prefill starts on every
     * path (Qwen only reports at the end of a chunk; DS4.1, GLM and CPU report no
     * initial position), so announce the reused prefix and the prompt size here,
     * once per sync, even when there is nothing left to evaluate. */
    if (progress) progress(ud, "prefill_start", cached, t->tokens.len);

    s->transcript_valid = false;
    s->cancel = cancel;
    s->cancel_ud = ud;
    ds4_session_set_progress(ss, progress, ud);
    ds4_session_set_display_progress(ss, progress, ud);
    ds4_session_set_cancel(ss, cancel ? zds4_cancel_trampoline : NULL, s);
    char err[ZDS4_DS4_ERR_CAP] = {0};
    const double t0 = zds4_now();
    const int sync_rc = t->span_count ?
        ds4_session_sync_multimodal(ss, &t->tokens, t->spans, t->span_count, err, sizeof(err)) :
        ds4_session_sync(ss, &t->tokens, err, sizeof(err));
    const double dt = zds4_now() - t0;
    ds4_session_set_cancel(ss, NULL, NULL);
    ds4_session_set_progress(ss, NULL, NULL);
    ds4_session_set_display_progress(ss, NULL, NULL);
    s->cancel = NULL;
    s->cancel_ud = NULL;

    zds4_reset_stats(s);
    s->stats[ZENCODE_DS4_STAT_PROMPT_TOKENS] = (double)t->tokens.len;
    s->stats[ZENCODE_DS4_STAT_CACHED_TOKENS] = (double)cached;
    s->stats[ZENCODE_DS4_STAT_EVALUATED_TOKENS] = (double)suffix;
    s->stats[ZENCODE_DS4_STAT_PREFILL_SECONDS] = dt;
    s->stats[ZENCODE_DS4_STAT_PREFILL_TOKENS_PER_SECOND] =
        sync_rc == 0 && dt > 0.0 ? (double)suffix / dt : 0.0;

    if (sync_rc == DS4_SESSION_SYNC_INTERRUPTED) return ZENCODE_DS4_SYNC_INTERRUPTED;
    if (sync_rc != 0) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_SESSION, "%s",
                         err[0] ? err : "session sync failed");
    }
    zds4_set_transcript(s, &t->tokens);
    s->synced_with_images = t->span_count > 0;
    return 0;
}

int32_t zencode_ds4_session_pos(void *session) {
    zds4_session *s = NULL;
    const int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    return (int32_t)ds4_session_pos(s->session);
}

int32_t zencode_ds4_session_ctx(void *session) {
    zds4_session *s = NULL;
    const int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    return (int32_t)ds4_session_ctx(s->session);
}

int32_t zencode_ds4_session_set_power(void *session, int32_t power_percent) {
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    if (power_percent < 1 || power_percent > 100) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "power must be between 1 and 100");
    }
    zds4_capture cap;
    zds4_capture_begin(&cap);
    const int set_rc = ds4_session_set_power(s->session, (int)power_percent);
    char *log = zds4_capture_end(&cap);
    if (set_rc != 0) {
        rc = zds4_fail_with_log(s->owner, ZENCODE_DS4_ERR_UNSUPPORTED,
                                "failed to change session power", log);
    }
    free(log);
    return rc;
}

int32_t zencode_ds4_session_set_directional_steering_ffn(void *session, double scale) {
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    if (!isfinite(scale) || scale < -100.0 || scale > 100.0) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "steering scale must be between -100 and 100");
    }
    zds4_capture cap;
    zds4_capture_begin(&cap);
    const int set_rc = ds4_session_set_directional_steering_ffn(s->session, (float)scale);
    char *log = zds4_capture_end(&cap);
    if (set_rc != 0) {
        rc = zds4_fail_with_log(s->owner, ZENCODE_DS4_ERR_UNSUPPORTED,
                                "failed to change directional steering", log);
    }
    free(log);
    return rc;
}

/* agent_worker_rewind (ds4_agent.c): rewind, then rebuild the retained
 * prefix when the rewind could not keep the checkpoint valid. */
static int32_t zds4_rewind_live(zds4_session *s, int pos) {
    ds4_session *ss = s->session;
    ds4_session_rewind(ss, pos);
    ds4_tokens prefix = {0};
    ds4_tokens_copy(&prefix, ds4_session_tokens(ss));
    int32_t rc = 0;
    if (ds4_session_common_prefix(ss, &prefix) != prefix.len) {
        if (s->synced_with_images) {
            rc = zds4_fail(s->owner, ZENCODE_DS4_ERR_UNSUPPORTED,
                           "rewind needs an image-aware rebuild; sync the session again");
        } else {
            char err[ZDS4_DS4_ERR_CAP] = {0};
            if (ds4_session_sync(ss, &prefix, err, sizeof(err)) != 0) {
                rc = zds4_fail(s->owner, ZENCODE_DS4_ERR_DECODE, "%s",
                               err[0] ? err : "rewind rebuild failed");
            }
        }
    }
    ds4_tokens_free(&prefix);
    return rc;
}

static void zds4_update_generation_stats(zds4_session *s, int generated, double t0) {
    const double dt = zds4_now() - t0;
    s->stats[ZENCODE_DS4_STAT_GENERATED_TOKENS] = (double)generated;
    s->stats[ZENCODE_DS4_STAT_GENERATION_SECONDS] = dt;
    s->stats[ZENCODE_DS4_STAT_GENERATION_TOKENS_PER_SECOND] =
        dt > 0.0 ? (double)generated / dt : 0.0;
}

int32_t zencode_ds4_session_generate(void *session, int32_t max_tokens, int32_t think_mode,
                                     double temperature, int32_t top_k, double top_p,
                                     double min_p, uint64_t seed, zencode_ds4_emit_fn emit,
                                     zencode_ds4_cancel_fn cancel, void *ud) {
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    zds4_engine *ze = s->owner;
    rc = zds4_check_think_mode(ze, think_mode);
    if (rc != 0) return rc;
    if (max_tokens < 0 || top_k < 0 || !isfinite(temperature) || temperature < 0.0 ||
        !isfinite(top_p) || top_p < 0.0 || top_p > 1.0 || !isfinite(min_p) || min_p < 0.0 ||
        min_p > 1.0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "invalid sampling parameters (max_tokens >= 0, temperature >= 0, "
                         "top_k >= 0, top_p and min_p in [0, 1])");
    }
    if (!s->transcript_valid) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "session_generate requires a successful session_sync or kv_load");
    }

    ds4_engine *e = ze->engine;
    ds4_session *ss = s->session;
    const ds4_think_mode mode = (ds4_think_mode)think_mode;
    const float temp = (float)temperature;
    const float tp = (float)top_p;
    const float mp = (float)min_p;

    int limit = (int)max_tokens;
    const int room = ds4_session_ctx(ss) - ds4_session_pos(ss);
    if (room <= 1) limit = 0;
    else if (limit > room - 1) limit = room - 1;

    uint64_t rng = seed ? seed :
        ((uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uint64_t)clock());
    int generated = 0;
    const double t0 = zds4_now();
    s->stats[ZENCODE_DS4_STAT_GENERATED_TOKENS] = 0.0;
    s->stats[ZENCODE_DS4_STAT_GENERATION_SECONDS] = 0.0;
    s->stats[ZENCODE_DS4_STAT_GENERATION_TOKENS_PER_SECOND] = 0.0;

    int32_t outcome = ZENCODE_DS4_GENERATE_MAX_TOKENS;
    bool greedy_next = false;
    char err[ZDS4_DS4_ERR_CAP];

    /* ds4-agent assistant generation loop (ds4_agent.c, run_agent turn). */
    while (generated < limit) {
        if (cancel && cancel(ud) != 0) {
            outcome = ZENCODE_DS4_GENERATE_CANCELLED;
            break;
        }
        const bool greedy = greedy_next;
        int token = ds4_session_sample(ss, greedy ? 0.0f : temp, greedy ? 0 : (int)top_k,
                                       greedy ? 1.0f : tp, greedy ? 0.0f : mp, &rng);
        if (token < 0) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_DECODE,
                           "sampling failed: the session has no valid logits");
            goto done;
        }
        if (ds4_token_is_stop_for_think_mode(e, token, mode)) {
            outcome = ZENCODE_DS4_GENERATE_STOP;
            break;
        }

        int toks[ZDS4_SPEC_TOKENS];
        int ntok = 0;
        const int block_start = ds4_session_pos(ss);
        err[0] = '\0';
        if (ds4_engine_mtp_draft_tokens(e) > 1 && getenv("DS4_MTP_SPEC_DISABLE") == NULL) {
            ntok = ds4_session_eval_speculative(ss, token, limit - generated, ds4_token_eos(e),
                                                greedy ? 0.0f : temp, greedy ? 0 : (int)top_k,
                                                greedy ? 1.0f : tp, greedy ? 0.0f : mp, &rng,
                                                toks, ZDS4_SPEC_TOKENS, err, sizeof(err));
            if (ntok < 0) {
                rc = zds4_fail(ze, ZENCODE_DS4_ERR_DECODE, "%s",
                               err[0] ? err : "speculative decode failed");
                goto done;
            }
        } else {
            if (ds4_session_eval(ss, token, err, sizeof(err)) != 0) {
                rc = zds4_fail(ze, ZENCODE_DS4_ERR_DECODE, "%s", err[0] ? err : "decode failed");
                goto done;
            }
            toks[0] = token;
            ntok = 1;
        }
        if (ntok == 0) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_DECODE, "decode returned no tokens");
            goto done;
        }

        bool stop_block = false;
        bool restart_sampling = false;
        for (int ti = 0; ti < ntok && generated < limit; ti++) {
            token = toks[ti];
            if (ds4_token_is_stop_for_think_mode(e, token, mode)) {
                ds4_session_rewind(ss, block_start + ti);
                outcome = ZENCODE_DS4_GENERATE_STOP;
                stop_block = true;
                break;
            }

            size_t text_len = 0;
            char *text = ds4_token_text(e, token, &text_len);
            /* The transcript receives exactly the committed tokens, in order:
             * never the stop token (handled above and by the sampling check)
             * and never the speculative tokens rewound after a stop or
             * EMIT_STOP.  The caller replays them as exact ids
             * (session_transcript_append_to + tokens_push). */
            ds4_tokens_push(&s->transcript, token);
            generated++;
            const int flags = emit ? emit(ud, text ? text : "", text ? text_len : 0) : 0;
            free(text);
            zds4_update_generation_stats(s, generated, t0);

            const bool next_greedy = (flags & ZENCODE_DS4_EMIT_GREEDY) != 0;
            greedy_next = next_greedy;
            if (flags & ZENCODE_DS4_EMIT_STOP) {
                if (ti + 1 < ntok) ds4_session_rewind(ss, block_start + ti + 1);
                outcome = ZENCODE_DS4_GENERATE_CALLER_STOP;
                stop_block = true;
                break;
            }

            /* Drafts proposed under the old mode only need a new distribution
             * with exact sampling: re-evaluate this boundary token to restore
             * its logits, then sample the suffix under the new mode. */
            if (ti + 1 < ntok && ds4_engine_mtp_exact_sampling(e) && temp > 0.0f &&
                next_greedy != greedy) {
                rc = zds4_rewind_live(s, block_start + ti);
                if (rc != 0) goto done;
                err[0] = '\0';
                if (ds4_session_eval(ss, token, err, sizeof(err)) != 0) {
                    rc = zds4_fail(ze, ZENCODE_DS4_ERR_DECODE, "%s",
                                   err[0] ? err : "decode failed");
                    goto done;
                }
                restart_sampling = true;
                break;
            }
        }
        if (stop_block) break;
        if (restart_sampling) continue;
    }
    rc = outcome;

done:
    zds4_update_generation_stats(s, generated, t0);
    return rc;
}

double zencode_ds4_stat(void *session, int32_t stat_id) {
    zds4_session *s = session;
    if (!s || !s->session || stat_id < 0 || stat_id >= ZENCODE_DS4_STAT_COUNT) return -1.0;
    if (stat_id == ZENCODE_DS4_STAT_SESSION_POS) return (double)ds4_session_pos(s->session);
    if (stat_id == ZENCODE_DS4_STAT_SESSION_CTX) return (double)ds4_session_ctx(s->session);
    return s->stats[stat_id];
}

int32_t zencode_ds4_session_transcript_len(void *session) {
    zds4_session *s = NULL;
    const int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    return (int32_t)s->transcript.len;
}

int32_t zencode_ds4_session_transcript_append_to(void *session, int32_t start, void *dst) {
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    zds4_tokens *t = NULL;
    rc = zds4_tokens_arg(s->owner, dst, &t);
    if (rc != 0) return rc;
    if (start < 0 || start > s->transcript.len) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "transcript start %d out of range (len %d)", (int)start,
                         s->transcript.len);
    }
    for (int i = (int)start; i < s->transcript.len; i++) ds4_tokens_push(&t->tokens, s->transcript.v[i]);
    return (int32_t)(s->transcript.len - start);
}

/* ------------------------------------------------------------------------
 * Disk KV (ds4_agent.c agent_kv_save_path / agent_kv_load_path)
 * --------------------------------------------------------------------- */

static bool zds4_tokens_equal(const ds4_tokens *a, const ds4_tokens *b) {
    if (!a || !b || a->len != b->len) return false;
    for (int i = 0; i < a->len; i++) {
        if (a->v[i] != b->v[i]) return false;
    }
    return true;
}

/* Bytes from the current position to EOF, restoring the position. */
static bool zds4_fp_remaining(FILE *fp, uint64_t *out) {
    const off_t pos = ftello(fp);
    if (pos < 0 || fseeko(fp, 0, SEEK_END) != 0) return false;
    const off_t end = ftello(fp);
    if (end < 0 || fseeko(fp, pos, SEEK_SET) != 0) return false;
    *out = end > pos ? (uint64_t)(end - pos) : 0;
    return true;
}

/* Reads `len` bytes (capped against the file size) into a NUL-terminated buffer. */
static int32_t zds4_read_blob(zds4_engine *ze, FILE *fp, uint32_t len, char **out,
                              const char *what) {
    *out = NULL;
    uint64_t remaining = 0;
    if (!zds4_fp_remaining(fp, &remaining) || len > remaining) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_KV_INVALID, "truncated %s", what);
    }
    char *buf = malloc((size_t)len + 1);
    if (!buf) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    if (len && fread(buf, 1, len, fp) != len) {
        free(buf);
        return zds4_fail(ze, ZENCODE_DS4_ERR_KV_INVALID, "truncated %s", what);
    }
    buf[len] = '\0';
    *out = buf;
    return 0;
}

/* Reads the trailer stored after the payload without moving the payload cursor
 * (agent_kv_read_title_trailer). */
static int32_t zds4_read_trailer(zds4_engine *ze, FILE *fp, uint64_t payload_bytes,
                                 char **out, uint32_t *out_len) {
    *out = NULL;
    *out_len = 0;
    const off_t payload_pos = ftello(fp);
    if (payload_pos < 0) return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s", strerror(errno));
    if (payload_bytes > (uint64_t)LLONG_MAX || fseeko(fp, (off_t)payload_bytes, SEEK_CUR) != 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_KV_INVALID, "KV payload extends past the file");
    }
    uint8_t tb[4];
    int32_t rc = 0;
    if (fread(tb, 1, sizeof(tb), fp) != sizeof(tb)) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INVALID, "missing KV trailer");
    } else {
        const uint32_t len = ds4_kvstore_le_get32(tb);
        rc = zds4_read_blob(ze, fp, len, out, "KV trailer");
        if (rc == 0) *out_len = len;
    }
    if (fseeko(fp, payload_pos, SEEK_SET) != 0 && rc == 0) {
        free(*out);
        *out = NULL;
        *out_len = 0;
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s", strerror(errno));
    }
    return rc;
}

static int32_t zds4_kv_save(zds4_session *s, const char *path, const char *trailer,
                            size_t trailer_len) {
    zds4_engine *ze = s->owner;
    ds4_engine *e = ze->engine;
    ds4_session *ss = s->session;

    const ds4_tokens *live = ds4_session_tokens(ss);
    if (!ds4_session_checkpoint_valid(ss) || !live || live->len <= 0) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "session has no valid KV checkpoint");
    }
    if (s->transcript_valid && !zds4_tokens_equal(live, &s->transcript)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT,
                         "live KV state does not match session transcript");
    }
    const int quant_bits = ds4_engine_routed_quant_bits(e);
    if (!ds4_kvstore_quant_bits_supported(quant_bits)) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_UNSUPPORTED,
                         "unsupported routed quantization for KV save");
    }
    const int model_id = ds4_engine_model_id(e);
    if (trailer && trailer_len > UINT32_MAX) {
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "KV trailer is too large");
    }

    size_t text_len = 0;
    char *text = ds4_kvstore_render_tokens_text(e, live, &text_len);
    if (!text) return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "failed to render KV text");
    if (text_len > UINT32_MAX) {
        free(text);
        return zds4_fail(ze, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "rendered KV text is too large");
    }

    ds4_session_payload_file staged;
    memset(&staged, 0, sizeof(staged));
    char save_err[ZDS4_DS4_ERR_CAP] = {0};
    if (ds4_session_stage_payload(ss, &staged, save_err, sizeof(save_err)) != 0) {
        free(text);
        return zds4_fail(ze, ZENCODE_DS4_ERR_SESSION, "%s",
                         save_err[0] ? save_err : "session has no valid KV payload");
    }

    const size_t path_len = strlen(path);
    char *tmp = malloc(path_len + sizeof(".tmp.XXXXXX"));
    if (!tmp) {
        ds4_session_payload_file_free(&staged);
        free(text);
        return zds4_fail(ze, ZENCODE_DS4_ERR_OUT_OF_MEMORY, "out of memory");
    }
    memcpy(tmp, path, path_len);
    memcpy(tmp + path_len, ".tmp.XXXXXX", sizeof(".tmp.XXXXXX"));
    const int fd = mkstemp(tmp);
    if (fd < 0) {
        const int saved = errno;
        ds4_session_payload_file_free(&staged);
        free(tmp);
        free(text);
        return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s: %s", path, strerror(saved));
    }
    FILE *fp = fdopen(fd, "wb");
    if (!fp) {
        const int saved = errno;
        close(fd);
        unlink(tmp);
        ds4_session_payload_file_free(&staged);
        free(tmp);
        free(text);
        return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s: %s", path, strerror(saved));
    }

    const uint64_t now = (uint64_t)time(NULL);
    uint8_t h[DS4_KVSTORE_FIXED_HEADER];
    ds4_kvstore_fill_header(h, (uint8_t)model_id, (uint8_t)quant_bits,
                            ds4_kvstore_reason_code("agent-session"),
                            trailer ? DS4_KVSTORE_EXT_SESSION_TITLE : 0,
                            (uint32_t)live->len, 0, (uint32_t)ds4_session_ctx(ss), now, now,
                            staged.bytes);
    uint8_t tb[4];
    ds4_kvstore_le_put32(tb, (uint32_t)text_len);
    uint8_t trailer_tb[4];
    ds4_kvstore_le_put32(trailer_tb, (uint32_t)(trailer ? trailer_len : 0));

    errno = 0;
    bool ok = fwrite(h, 1, sizeof(h), fp) == sizeof(h) &&
              fwrite(tb, 1, sizeof(tb), fp) == sizeof(tb) &&
              fwrite(text, 1, text_len, fp) == text_len &&
              ds4_session_write_staged_payload(&staged, fp, save_err, sizeof(save_err)) == 0 &&
              (!trailer ||
               (fwrite(trailer_tb, 1, sizeof(trailer_tb), fp) == sizeof(trailer_tb) &&
                fwrite(trailer, 1, trailer_len, fp) == trailer_len)) &&
              fflush(fp) == 0;
    int saved_errno = errno;
    if (fclose(fp) != 0) {
        if (!saved_errno) saved_errno = errno;
        ok = false;
    }
    if (ok && rename(tmp, path) != 0) {
        saved_errno = errno;
        ok = false;
    }
    int32_t rc = 0;
    if (!ok) {
        unlink(tmp);
        if (save_err[0]) rc = zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s: %s", path, save_err);
        else rc = zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s: %s", path,
                            saved_errno ? strerror(saved_errno) : "write failed");
    }
    ds4_session_payload_file_free(&staged);
    free(tmp);
    free(text);
    return rc;
}

int32_t zencode_ds4_session_kv_save(void *session, const char *path, const char *trailer,
                                    size_t trailer_len) {
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    if (!path || !path[0]) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "KV path is empty");
    }
    if (ds4_session_has_vision_state(s->session)) {
        zds4_fail(s->owner, ZENCODE_DS4_KV_SKIPPED_VISION,
                  "KV save skipped: the session holds image-conditioned state");
        return ZENCODE_DS4_KV_SKIPPED_VISION;
    }
    zds4_capture cap;
    zds4_capture_begin(&cap);
    rc = zds4_kv_save(s, path, trailer, trailer_len);
    char *log = zds4_capture_end(&cap);
    if (rc < 0) {
        char message[ZDS4_ERR_CAP];
        snprintf(message, sizeof(message), "%s", g_last_error);
        rc = zds4_fail_with_log(s->owner, rc, message, log);
    }
    free(log);
    return rc;
}

static int32_t zds4_kv_load(zds4_session *s, const char *path, char **out_trailer,
                            size_t *out_trailer_len) {
    zds4_engine *ze = s->owner;
    ds4_engine *e = ze->engine;
    ds4_session *ss = s->session;
    const int ctx = ds4_session_ctx(ss);

    if (ze->opt.distributed.role == DS4_DISTRIBUTED_COORDINATOR) {
        char err[ZDS4_DS4_ERR_CAP] = {0};
        if (ds4_session_distributed_route_ready(ss, err, sizeof(err)) <= 0) {
            return zds4_fail(ze, ZENCODE_DS4_ERR_SESSION,
                             "distributed route is not ready (%s); call "
                             "zencode_ds4_session_wait_distributed_route first",
                             err[0] ? err : "route incomplete");
        }
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) return zds4_fail(ze, ZENCODE_DS4_ERR_IO, "%s: %s", path, strerror(errno));

    double t0 = zds4_now();
    ds4_kvstore_entry hdr;
    memset(&hdr, 0, sizeof(hdr));
    uint32_t text_bytes = 0;
    char *text = NULL;
    char *trailer = NULL;
    uint32_t trailer_len = 0;
    ds4_tokens rebuilt = {0};
    bool touched_session = false;
    int32_t rc = 0;

    if (!ds4_kvstore_read_header(fp, &hdr, &text_bytes)) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INVALID, "invalid KV header");
    }
    if (rc == 0) rc = zds4_read_blob(ze, fp, text_bytes, &text, "cached text");
    if (rc == 0 && (hdr.ext_flags & DS4_KVSTORE_EXT_SESSION_TITLE)) {
        rc = zds4_read_trailer(ze, fp, hdr.payload_bytes, &trailer, &trailer_len);
    }
    if (rc == 0 && hdr.payload_bytes != 0 && hdr.model_id != (uint8_t)ds4_engine_model_id(e)) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                       "KV checkpoint was written for a different model");
    }
    if (rc == 0 && hdr.payload_bytes != 0 &&
        hdr.quant_bits != (uint8_t)ds4_engine_routed_quant_bits(e)) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                       "KV checkpoint was written for a different quantization");
    }

    const bool rebuild = hdr.payload_bytes == 0 || ds4_tp_enabled(&ze->opt.tp);
    if (rc == 0 && !rebuild && hdr.ctx_size > (uint32_t)ctx) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                       "KV checkpoint was written for a larger context (%u > %d)",
                       (unsigned)hdr.ctx_size, ctx);
    }
    if (rc == 0 && hdr.tokens >= (uint32_t)ctx) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                       "KV checkpoint (%u tokens) does not fit the session context (%d)",
                       (unsigned)hdr.tokens, ctx);
    }

    uint32_t expected_tokens = hdr.tokens;
    if (rc == 0) {
        char err[ZDS4_DS4_ERR_CAP] = {0};
        if (rebuild) {
            /* A payload holds only the local graph state: rebuild from the
             * rendered text so a TP worker mirrors the same prefix. */
            ds4_tokenize_rendered_chat(e, text, &rebuilt);
            expected_tokens = (uint32_t)rebuilt.len;
            if (rebuilt.len <= 0 || rebuilt.len >= ctx) {
                rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                               "KV text (%d tokens) does not fit the session context (%d)",
                               rebuilt.len, ctx);
            } else {
                s->transcript_valid = false;
                touched_session = true;
                if (ds4_session_sync(ss, &rebuilt, err, sizeof(err)) != 0) {
                    rc = zds4_fail(ze, ZENCODE_DS4_ERR_SESSION, "%s",
                                   err[0] ? err : "KV rebuild failed");
                }
            }
        } else {
            s->transcript_valid = false;
            touched_session = true;
            if (ds4_session_load_payload(ss, fp, hdr.payload_bytes, err, sizeof(err)) != 0) {
                rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE, "%s",
                               err[0] ? err : "failed to load KV payload");
            }
        }
    }
    fclose(fp);

    const ds4_tokens *live = rc == 0 ? ds4_session_tokens(ss) : NULL;
    if (rc == 0 && (!live || live->len != (int)expected_tokens)) {
        rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE, "KV payload token count mismatch");
    }
    if (rc == 0) {
        /* The stored text must be exactly the rendering of the loaded tokens,
         * and its re-tokenization must agree with them at least on a prefix
         * (sampled tokens may use non-canonical BPE splits). */
        size_t rendered_len = 0;
        char *rendered = ds4_kvstore_render_tokens_text(e, live, &rendered_len);
        if (!rendered || rendered_len != (size_t)text_bytes ||
            memcmp(rendered, text, rendered_len) != 0) {
            rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                           "KV text does not match the loaded tokens");
        }
        free(rendered);
        if (rc == 0 && !rebuild) ds4_tokenize_rendered_chat(e, text, &rebuilt);
        if (rc == 0) {
            int common = 0;
            while (common < rebuilt.len && common < live->len &&
                   rebuilt.v[common] == live->v[common]) {
                common++;
            }
            if (common == 0) {
                rc = zds4_fail(ze, ZENCODE_DS4_ERR_KV_INCOMPATIBLE,
                               "re-tokenized KV text diverges from the loaded tokens");
            }
        }
    }

    if (rc != 0) {
        if (touched_session) ds4_session_invalidate(ss);
        free(trailer);
    } else {
        zds4_set_transcript(s, live);
        s->synced_with_images = false;
        zds4_reset_stats(s);
        const double dt = zds4_now() - t0;
        s->stats[ZENCODE_DS4_STAT_PROMPT_TOKENS] = (double)live->len;
        s->stats[ZENCODE_DS4_STAT_CACHED_TOKENS] = rebuild ? 0.0 : (double)live->len;
        s->stats[ZENCODE_DS4_STAT_EVALUATED_TOKENS] = rebuild ? (double)live->len : 0.0;
        s->stats[ZENCODE_DS4_STAT_PREFILL_SECONDS] = dt;
        s->stats[ZENCODE_DS4_STAT_PREFILL_TOKENS_PER_SECOND] =
            rebuild && dt > 0.0 ? (double)live->len / dt : 0.0;
        if (out_trailer) *out_trailer = trailer;
        else free(trailer);
        if (out_trailer_len) *out_trailer_len = trailer ? (size_t)trailer_len : 0;
    }
    ds4_tokens_free(&rebuilt);
    free(text);
    return rc;
}

int32_t zencode_ds4_session_kv_load(void *session, const char *path, char **out_trailer,
                                    size_t *out_trailer_len) {
    if (out_trailer) *out_trailer = NULL;
    if (out_trailer_len) *out_trailer_len = 0;
    zds4_session *s = NULL;
    int32_t rc = zds4_session_arg(session, &s);
    if (rc != 0) return rc;
    if (!path || !path[0]) {
        return zds4_fail(s->owner, ZENCODE_DS4_ERR_INVALID_ARGUMENT, "KV path is empty");
    }
    zds4_capture cap;
    zds4_capture_begin(&cap);
    rc = zds4_kv_load(s, path, out_trailer, out_trailer_len);
    char *log = zds4_capture_end(&cap);
    if (rc < 0) {
        char message[ZDS4_ERR_CAP];
        snprintf(message, sizeof(message), "%s", g_last_error);
        rc = zds4_fail_with_log(s->owner, rc, message, log);
    }
    free(log);
    return rc;
}
