#include "DS4RuntimeShim.h"

#include <ds4.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

_Static_assert((int)ZENCODE_DS4_BACKEND_METAL == (int)DS4_BACKEND_METAL, "DS4 backend enum mismatch");
_Static_assert((int)ZENCODE_DS4_BACKEND_CUDA == (int)DS4_BACKEND_CUDA, "DS4 backend enum mismatch");
_Static_assert((int)ZENCODE_DS4_BACKEND_CPU == (int)DS4_BACKEND_CPU, "DS4 backend enum mismatch");
_Static_assert((int)ZENCODE_DS4_THINK_NONE == (int)DS4_THINK_NONE, "DS4 think-mode enum mismatch");
_Static_assert((int)ZENCODE_DS4_THINK_HIGH == (int)DS4_THINK_HIGH, "DS4 think-mode enum mismatch");
_Static_assert((int)ZENCODE_DS4_THINK_MAX == (int)DS4_THINK_MAX, "DS4 think-mode enum mismatch");

typedef int (*ds4_engine_open_fn)(ds4_engine **out, const ds4_engine_options *opt);
typedef void (*ds4_engine_close_fn)(ds4_engine *e);
typedef const char *(*ds4_engine_model_name_fn)(ds4_engine *e);
typedef const char *(*ds4_backend_name_fn)(ds4_backend backend);
typedef int (*ds4_session_create_fn)(ds4_session **out, ds4_engine *e, int ctx_size);
typedef void (*ds4_session_free_fn)(ds4_session *s);
typedef int (*ds4_session_common_prefix_fn)(ds4_session *s, const ds4_tokens *prompt);
typedef int (*ds4_session_sync_fn)(ds4_session *s, const ds4_tokens *prompt, char *err, size_t errlen);
typedef int (*ds4_session_sample_fn)(ds4_session *s, float temperature, int top_k, float top_p, float min_p, uint64_t *rng);
typedef int (*ds4_session_eval_fn)(ds4_session *s, int token, char *err, size_t errlen);
typedef int (*ds4_session_pos_fn)(ds4_session *s);
typedef int (*ds4_session_ctx_fn)(ds4_session *s);
typedef void (*ds4_session_invalidate_fn)(ds4_session *s);
typedef void (*ds4_tokens_push_fn)(ds4_tokens *tv, int token);
typedef void (*ds4_tokens_free_fn)(ds4_tokens *tv);
typedef void (*ds4_chat_begin_fn)(ds4_engine *e, ds4_tokens *tokens);
typedef void (*ds4_chat_append_message_fn)(ds4_engine *e, ds4_tokens *tokens, const char *role, const char *content);
typedef void (*ds4_chat_append_assistant_prefix_fn)(ds4_engine *e, ds4_tokens *tokens, ds4_think_mode think_mode);
typedef char *(*ds4_token_text_fn)(ds4_engine *e, int token, size_t *len);
typedef int (*ds4_token_eos_fn)(ds4_engine *e);
typedef ds4_think_mode (*ds4_think_mode_for_context_fn)(ds4_think_mode mode, int ctx_size);

typedef struct {
    ds4_engine_open_fn engine_open;
    ds4_engine_close_fn engine_close;
    ds4_engine_model_name_fn engine_model_name;
    ds4_backend_name_fn backend_name;
    ds4_session_create_fn session_create;
    ds4_session_free_fn session_free;
    ds4_session_common_prefix_fn session_common_prefix;
    ds4_session_sync_fn session_sync;
    ds4_session_sample_fn session_sample;
    ds4_session_eval_fn session_eval;
    ds4_session_pos_fn session_pos;
    ds4_session_ctx_fn session_ctx;
    ds4_session_invalidate_fn session_invalidate;
    ds4_tokens_push_fn tokens_push;
    ds4_tokens_free_fn tokens_free;
    ds4_chat_begin_fn chat_begin;
    ds4_chat_append_message_fn chat_append_message;
    ds4_chat_append_assistant_prefix_fn chat_append_assistant_prefix;
    ds4_token_text_fn token_text;
    ds4_token_eos_fn token_eos;
    ds4_think_mode_for_context_fn think_mode_for_context;
} ds4_symbols;

struct zencode_ds4_engine {
    void *handle;
    ds4_engine *engine;
    ds4_symbols sym;
    char *library_path;
};

struct zencode_ds4_session {
    zencode_ds4_engine *owner;
    ds4_session *session;
    ds4_tokens transcript;
    int ctx_size;
};

static void set_error(char *error, size_t error_len, const char *message) {
    if (!error || error_len == 0) return;
    snprintf(error, error_len, "%s", message ? message : "unknown DS4 error");
}

static void set_errorf(char *error, size_t error_len, const char *fmt, const char *arg) {
    if (!error || error_len == 0) return;
    snprintf(error, error_len, fmt, arg ? arg : "");
}

static char *join_path(const char *root, const char *relative) {
    if (!root || !root[0] || !relative || !relative[0]) return NULL;
    size_t root_len = strlen(root);
    size_t relative_len = strlen(relative);
    bool slash = root[root_len - 1] == '/';
    char *out = (char *)malloc(root_len + (slash ? 0 : 1) + relative_len + 1);
    if (!out) return NULL;
    memcpy(out, root, root_len);
    size_t pos = root_len;
    if (!slash) out[pos++] = '/';
    memcpy(out + pos, relative, relative_len);
    out[pos + relative_len] = '\0';
    return out;
}

static void set_metal_source_env(const char *root, const char *name, const char *relative) {
    if (!root || !root[0] || getenv(name)) return;
    char *path = join_path(root, relative);
    if (!path) return;
    setenv(name, path, 0);
    free(path);
}

static pthread_mutex_t metal_source_env_mutex = PTHREAD_MUTEX_INITIALIZER;

static void configure_metal_sources(const char *root) {
    pthread_mutex_lock(&metal_source_env_mutex);
    set_metal_source_env(root, "DS4_METAL_FLASH_ATTN_SOURCE", "metal/flash_attn.metal");
    set_metal_source_env(root, "DS4_METAL_DENSE_SOURCE", "metal/dense.metal");
    set_metal_source_env(root, "DS4_METAL_MOE_SOURCE", "metal/moe.metal");
    set_metal_source_env(root, "DS4_METAL_DSV4_HC_SOURCE", "metal/dsv4_hc.metal");
    set_metal_source_env(root, "DS4_METAL_UNARY_SOURCE", "metal/unary.metal");
    set_metal_source_env(root, "DS4_METAL_DSV4_KV_SOURCE", "metal/dsv4_kv.metal");
    set_metal_source_env(root, "DS4_METAL_DSV4_ROPE_SOURCE", "metal/dsv4_rope.metal");
    set_metal_source_env(root, "DS4_METAL_DSV4_MISC_SOURCE", "metal/dsv4_misc.metal");
    set_metal_source_env(root, "DS4_METAL_ARGSORT_SOURCE", "metal/argsort.metal");
    set_metal_source_env(root, "DS4_METAL_CPY_SOURCE", "metal/cpy.metal");
    set_metal_source_env(root, "DS4_METAL_CONCAT_SOURCE", "metal/concat.metal");
    set_metal_source_env(root, "DS4_METAL_GET_ROWS_SOURCE", "metal/get_rows.metal");
    set_metal_source_env(root, "DS4_METAL_SUM_ROWS_SOURCE", "metal/sum_rows.metal");
    set_metal_source_env(root, "DS4_METAL_SOFTMAX_SOURCE", "metal/softmax.metal");
    set_metal_source_env(root, "DS4_METAL_REPEAT_SOURCE", "metal/repeat.metal");
    set_metal_source_env(root, "DS4_METAL_GLU_SOURCE", "metal/glu.metal");
    set_metal_source_env(root, "DS4_METAL_NORM_SOURCE", "metal/norm.metal");
    set_metal_source_env(root, "DS4_METAL_BIN_SOURCE", "metal/bin.metal");
    set_metal_source_env(root, "DS4_METAL_SET_ROWS_SOURCE", "metal/set_rows.metal");
    pthread_mutex_unlock(&metal_source_env_mutex);
}

static void *required_symbol(void *handle, const char *name, char *error, size_t error_len) {
    dlerror();
    void *sym = dlsym(handle, name);
    const char *dl_error = dlerror();
    if (dl_error || !sym) {
        set_errorf(error, error_len, "DS4 symbol not found: %s", name);
        return NULL;
    }
    return sym;
}

static int resolve_symbols(void *handle, ds4_symbols *sym, char *error, size_t error_len) {
#define RESOLVE(field, type, name) do { \
    sym->field = (type)required_symbol(handle, name, error, error_len); \
    if (!sym->field) return 1; \
} while (0)
    RESOLVE(engine_open, ds4_engine_open_fn, "ds4_engine_open");
    RESOLVE(engine_close, ds4_engine_close_fn, "ds4_engine_close");
    RESOLVE(engine_model_name, ds4_engine_model_name_fn, "ds4_engine_model_name");
    RESOLVE(backend_name, ds4_backend_name_fn, "ds4_backend_name");
    RESOLVE(session_create, ds4_session_create_fn, "ds4_session_create");
    RESOLVE(session_free, ds4_session_free_fn, "ds4_session_free");
    RESOLVE(session_common_prefix, ds4_session_common_prefix_fn, "ds4_session_common_prefix");
    RESOLVE(session_sync, ds4_session_sync_fn, "ds4_session_sync");
    RESOLVE(session_sample, ds4_session_sample_fn, "ds4_session_sample");
    RESOLVE(session_eval, ds4_session_eval_fn, "ds4_session_eval");
    RESOLVE(session_pos, ds4_session_pos_fn, "ds4_session_pos");
    RESOLVE(session_ctx, ds4_session_ctx_fn, "ds4_session_ctx");
    RESOLVE(session_invalidate, ds4_session_invalidate_fn, "ds4_session_invalidate");
    RESOLVE(tokens_push, ds4_tokens_push_fn, "ds4_tokens_push");
    RESOLVE(tokens_free, ds4_tokens_free_fn, "ds4_tokens_free");
    RESOLVE(chat_begin, ds4_chat_begin_fn, "ds4_chat_begin");
    RESOLVE(chat_append_message, ds4_chat_append_message_fn, "ds4_chat_append_message");
    RESOLVE(chat_append_assistant_prefix, ds4_chat_append_assistant_prefix_fn, "ds4_chat_append_assistant_prefix");
    RESOLVE(token_text, ds4_token_text_fn, "ds4_token_text");
    RESOLVE(token_eos, ds4_token_eos_fn, "ds4_token_eos");
    RESOLVE(think_mode_for_context, ds4_think_mode_for_context_fn, "ds4_think_mode_for_context");
#undef RESOLVE
    return 0;
}

int zencode_ds4_engine_open(
    const zencode_ds4_engine_options *options,
    zencode_ds4_engine **out,
    char *error,
    size_t error_len
) {
    if (!out) {
        set_error(error, error_len, "missing DS4 engine output pointer");
        return 1;
    }
    *out = NULL;
    if (!options) {
        set_error(error, error_len, "missing DS4 engine options");
        return 1;
    }

    configure_metal_sources(options->ds4_root);

    char *default_library_path = NULL;
    const char *library_path = options->library_path;
    if ((!library_path || !library_path[0]) && options->ds4_root && options->ds4_root[0]) {
#if defined(__APPLE__)
        default_library_path = join_path(options->ds4_root, "libds4.dylib");
#else
        default_library_path = join_path(options->ds4_root, "libds4.so");
#endif
        library_path = default_library_path;
    }
    if (!library_path || !library_path[0]) {
        free(default_library_path);
        set_error(error, error_len, "missing DS4 library path");
        return 1;
    }
    if (!options->model_path || !options->model_path[0]) {
        free(default_library_path);
        set_error(error, error_len, "missing DS4 model path");
        return 1;
    }

    void *handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        set_errorf(error, error_len, "unable to load DS4 library: %s", dlerror());
        free(default_library_path);
        return 1;
    }

    zencode_ds4_engine *engine = (zencode_ds4_engine *)calloc(1, sizeof(*engine));
    if (!engine) {
        dlclose(handle);
        free(default_library_path);
        set_error(error, error_len, "out of memory opening DS4 engine");
        return 1;
    }
    engine->handle = handle;
    engine->library_path = strdup(library_path);
    if (!engine->library_path) {
        set_error(error, error_len, "out of memory duplicating DS4 library path");
        zencode_ds4_engine_close(engine);
        free(default_library_path);
        return 1;
    }

    if (resolve_symbols(handle, &engine->sym, error, error_len) != 0) {
        zencode_ds4_engine_close(engine);
        free(default_library_path);
        return 1;
    }

    ds4_engine_options ds4_options;
    memset(&ds4_options, 0, sizeof(ds4_options));
    ds4_options.model_path = options->model_path;
    ds4_options.mtp_path = options->mtp_path;
    ds4_options.backend = (ds4_backend)options->backend;
    ds4_options.n_threads = options->n_threads;
    ds4_options.prefill_chunk = options->prefill_chunk;
    ds4_options.mtp_draft_tokens = options->mtp_draft_tokens > 0 ? options->mtp_draft_tokens : 1;
    ds4_options.mtp_margin = options->mtp_margin >= 0.0f ? options->mtp_margin : 3.0f;
    ds4_options.power_percent = options->power_percent > 0 ? options->power_percent : 100;
    ds4_options.ssd_streaming_cache_experts = options->ssd_streaming_cache_experts;
    ds4_options.ssd_streaming_cache_bytes = options->ssd_streaming_cache_bytes;
    ds4_options.ssd_streaming_preload_experts = options->ssd_streaming_preload_experts;
    ds4_options.quality = options->quality;
    ds4_options.ssd_streaming = options->ssd_streaming;
    ds4_options.ssd_streaming_cold = options->ssd_streaming_cold;
    ds4_options.distributed.role = DS4_DISTRIBUTED_NONE;

    if (engine->sym.engine_open(&engine->engine, &ds4_options) != 0 || !engine->engine) {
        set_error(error, error_len, "DS4 failed to open the model");
        zencode_ds4_engine_close(engine);
        free(default_library_path);
        return 1;
    }

    *out = engine;
    free(default_library_path);
    return 0;
}

void zencode_ds4_engine_close(zencode_ds4_engine *engine) {
    if (!engine) return;
    if (engine->engine && engine->sym.engine_close) {
        engine->sym.engine_close(engine->engine);
    }
    if (engine->handle) {
        dlclose(engine->handle);
    }
    free(engine->library_path);
    free(engine);
}

const char *zencode_ds4_engine_model_name(zencode_ds4_engine *engine) {
    if (!engine || !engine->engine || !engine->sym.engine_model_name) return NULL;
    return engine->sym.engine_model_name(engine->engine);
}

zencode_ds4_think_mode zencode_ds4_engine_effective_think_mode(
    zencode_ds4_engine *engine,
    zencode_ds4_think_mode think_mode,
    int ctx_size
) {
    if (!engine || !engine->engine || !engine->sym.think_mode_for_context) {
        return think_mode;
    }
    int resolved_ctx = ctx_size > 0 ? ctx_size : 65536;
    return (zencode_ds4_think_mode)engine->sym.think_mode_for_context(
        (ds4_think_mode)think_mode,
        resolved_ctx
    );
}

const char *zencode_ds4_backend_name(zencode_ds4_backend backend) {
    switch (backend) {
    case ZENCODE_DS4_BACKEND_METAL:
        return "metal";
    case ZENCODE_DS4_BACKEND_CUDA:
        return "cuda";
    case ZENCODE_DS4_BACKEND_CPU:
        return "cpu";
    default:
        return "unknown";
    }
}

int zencode_ds4_session_create(
    zencode_ds4_engine *engine,
    int ctx_size,
    zencode_ds4_session **out,
    char *error,
    size_t error_len
) {
    if (!out) {
        set_error(error, error_len, "missing DS4 session output pointer");
        return 1;
    }
    *out = NULL;
    if (!engine || !engine->engine) {
        set_error(error, error_len, "DS4 engine is not open");
        return 1;
    }

    zencode_ds4_session *session = (zencode_ds4_session *)calloc(1, sizeof(*session));
    if (!session) {
        set_error(error, error_len, "out of memory creating DS4 session");
        return 1;
    }
    session->owner = engine;
    session->ctx_size = ctx_size > 0 ? ctx_size : 65536;
    if (engine->sym.session_create(&session->session, engine->engine, session->ctx_size) != 0 || !session->session) {
        free(session);
        set_error(error, error_len, "DS4 failed to create an inference session");
        return 1;
    }
    engine->sym.chat_begin(engine->engine, &session->transcript);
    *out = session;
    return 0;
}

void zencode_ds4_session_free(zencode_ds4_session *session) {
    if (!session) return;
    if (session->owner && session->owner->sym.tokens_free) {
        session->owner->sym.tokens_free(&session->transcript);
    }
    if (session->session && session->owner && session->owner->sym.session_free) {
        session->owner->sym.session_free(session->session);
    }
    free(session);
}

void zencode_ds4_session_reset(zencode_ds4_session *session) {
    if (!session || !session->owner) return;
    session->owner->sym.tokens_free(&session->transcript);
    memset(&session->transcript, 0, sizeof(session->transcript));
    session->owner->sym.chat_begin(session->owner->engine, &session->transcript);
    if (session->owner->sym.session_invalidate) {
        session->owner->sym.session_invalidate(session->session);
    }
}

void zencode_ds4_session_append_message(
    zencode_ds4_session *session,
    const char *role,
    const char *content
) {
    if (!session || !session->owner) return;
    session->owner->sym.chat_append_message(
        session->owner->engine,
        &session->transcript,
        role ? role : "user",
        content ? content : ""
    );
}

void zencode_ds4_session_append_eos(zencode_ds4_session *session) {
    if (!session || !session->owner) return;
    int eos = session->owner->sym.token_eos(session->owner->engine);
    session->owner->sym.tokens_push(&session->transcript, eos);
}

static uint64_t default_seed(void) {
    return ((uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uint64_t)clock());
}

static double monotonic_seconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return (double)clock() / (double)CLOCKS_PER_SEC;
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int ds4_tool_stop_tail_matches(const char *tail, size_t tail_len) {
    static const char *const markers[] = {
        "</｜DSML｜tool_calls>",
        "</DSML｜tool_calls>",
        "</tool_calls>",
    };
    const size_t marker_count = sizeof(markers) / sizeof(markers[0]);
    for (size_t i = 0; i < marker_count; i++) {
        size_t marker_len = strlen(markers[i]);
        if (tail_len >= marker_len &&
            memcmp(tail + tail_len - marker_len, markers[i], marker_len) == 0) {
            return 1;
        }
    }
    return 0;
}

static void ds4_tool_stop_tail_append(char *tail, size_t *tail_len, const char *text, size_t text_len) {
    static const size_t tail_cap = 96;
    if (!text || text_len == 0) return;
    if (text_len >= tail_cap) {
        memcpy(tail, text + text_len - tail_cap + 1, tail_cap - 1);
        *tail_len = tail_cap - 1;
        tail[*tail_len] = '\0';
        return;
    }
    if (*tail_len + text_len >= tail_cap) {
        size_t drop = *tail_len + text_len - tail_cap + 1;
        memmove(tail, tail + drop, *tail_len - drop);
        *tail_len -= drop;
    }
    memcpy(tail + *tail_len, text, text_len);
    *tail_len += text_len;
    tail[*tail_len] = '\0';
}

int zencode_ds4_session_generate(
    zencode_ds4_session *session,
    const char *prompt,
    int max_tokens,
    float temperature,
    int top_k,
    float top_p,
    float min_p,
    uint64_t seed,
    zencode_ds4_think_mode think_mode,
    zencode_ds4_emit_fn emit,
    void *emit_user_data,
    zencode_ds4_should_continue_fn should_continue,
    void *should_continue_user_data,
    zencode_ds4_generation_stats *stats,
    char *error,
    size_t error_len
) {
    if (!session || !session->owner || !session->session) {
        set_error(error, error_len, "DS4 session is not available");
        return 1;
    }
    if (stats) {
        memset(stats, 0, sizeof(*stats));
        stats->finish_reason = 0;
    }
    if (max_tokens <= 0) max_tokens = 50000;
    if (top_k < 0) top_k = 0;
    if (top_p <= 0.0f || top_p > 1.0f) top_p = 1.0f;
    if (min_p < 0.0f || min_p > 1.0f) min_p = 0.05f;
    if (temperature < 0.0f) temperature = 0.0f;

    ds4_symbols *sym = &session->owner->sym;
    ds4_think_mode effective_think_mode = sym->think_mode_for_context(
        (ds4_think_mode)think_mode,
        session->ctx_size
    );
    if (stats) {
        stats->effective_think_mode = (int)effective_think_mode;
    }
    int rollback_len = session->transcript.len;
    if (should_continue && !should_continue(should_continue_user_data)) {
        if (stats) stats->finish_reason = 4;
        return 0;
    }
    if (prompt && prompt[0]) {
        sym->chat_append_message(session->owner->engine, &session->transcript, "user", prompt);
    }
    sym->chat_append_assistant_prefix(session->owner->engine, &session->transcript, effective_think_mode);

    int old_pos = sym->session_pos(session->session);
    int common = sym->session_common_prefix(session->session, &session->transcript);
    int cached = (common == old_pos && session->transcript.len >= old_pos) ? common : 0;
    int suffix = session->transcript.len - cached;
    if (stats) {
        stats->prompt_tokens = suffix;
        stats->cached_prompt_tokens = cached;
        stats->evaluated_prompt_tokens = suffix;
        stats->live_tokens_before = old_pos;
        stats->common_prefix_tokens = common;
        stats->transcript_tokens = session->transcript.len;
    }

    char ds4_error[256] = {0};
    double prompt_start = monotonic_seconds();
    int sync_rc = sym->session_sync(session->session, &session->transcript, ds4_error, sizeof(ds4_error));
    double prompt_end = monotonic_seconds();
    if (sync_rc != 0) {
        session->transcript.len = rollback_len;
        set_error(error, error_len, ds4_error[0] ? ds4_error : "DS4 prompt processing failed");
        if (stats) stats->finish_reason = 2;
        return 1;
    }

    int finish_reason = 0;
    int room = sym->session_ctx(session->session) - sym->session_pos(session->session);
    if (room <= 1) {
        max_tokens = 0;
        finish_reason = 1;
    } else if (max_tokens > room - 1) {
        max_tokens = room - 1;
    }

    uint64_t rng = seed ? seed : default_seed();
    int generated = 0;
    int eos = sym->token_eos(session->owner->engine);
    char tool_stop_tail[96] = {0};
    size_t tool_stop_tail_len = 0;
    double generation_start = monotonic_seconds();
    while (generated < max_tokens) {
        if (should_continue && !should_continue(should_continue_user_data)) {
            finish_reason = 4;
            break;
        }
        int token = sym->session_sample(session->session, temperature, top_k, top_p, min_p, &rng);
        if (token == eos) {
            finish_reason = 0;
            break;
        }
        if (sym->session_eval(session->session, token, ds4_error, sizeof(ds4_error)) != 0) {
            session->transcript.len = rollback_len;
            set_error(error, error_len, ds4_error[0] ? ds4_error : "DS4 decode failed");
            if (stats) stats->finish_reason = 2;
            return 1;
        }
        sym->tokens_push(&session->transcript, token);
        size_t text_len = 0;
        char *text = sym->token_text(session->owner->engine, token, &text_len);
        if (emit) {
            if (text && text_len > 0) {
                emit(emit_user_data, text, text_len);
            }
        }
        if (text && text_len > 0) {
            ds4_tool_stop_tail_append(tool_stop_tail, &tool_stop_tail_len, text, text_len);
            if (ds4_tool_stop_tail_matches(tool_stop_tail, tool_stop_tail_len)) {
                finish_reason = 3;
                free(text);
                generated++;
                break;
            }
        }
        free(text);
        generated++;
    }
    if (finish_reason == 0 && generated >= max_tokens && max_tokens > 0) {
        finish_reason = 1;
    }
    sym->tokens_push(&session->transcript, eos);
    double generation_end = monotonic_seconds();

    if (stats) {
        double prompt_seconds = prompt_end - prompt_start;
        double generation_seconds = generation_end - generation_start;
        stats->generated_tokens = generated;
        stats->session_pos = sym->session_pos(session->session);
        stats->finish_reason = finish_reason;
        stats->prompt_seconds = prompt_seconds;
        stats->generation_seconds = generation_seconds;
        stats->prompt_tokens_per_second = prompt_seconds > 0.0 ? (double)suffix / prompt_seconds : 0.0;
        stats->generation_tokens_per_second = generation_seconds > 0.0 ? (double)generated / generation_seconds : 0.0;
    }
    return 0;
}

int zencode_ds4_session_transcript_len(zencode_ds4_session *session) {
    return session ? session->transcript.len : 0;
}

int zencode_ds4_session_pos(zencode_ds4_session *session) {
    if (!session || !session->owner || !session->session) return 0;
    return session->owner->sym.session_pos(session->session);
}

int zencode_ds4_session_ctx(zencode_ds4_session *session) {
    if (!session || !session->owner || !session->session) return 0;
    return session->owner->sym.session_ctx(session->session);
}
