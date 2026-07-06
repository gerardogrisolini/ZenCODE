#ifndef DS4_RUNTIME_SHIM_H
#define DS4_RUNTIME_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ZENCODE_DS4_BACKEND_METAL = 0,
    ZENCODE_DS4_BACKEND_CUDA = 1,
    ZENCODE_DS4_BACKEND_CPU = 2,
} zencode_ds4_backend;

typedef enum {
    ZENCODE_DS4_THINK_NONE = 0,
    ZENCODE_DS4_THINK_HIGH = 1,
    ZENCODE_DS4_THINK_MAX = 2,
} zencode_ds4_think_mode;

typedef struct {
    const char *ds4_root;
    const char *library_path;
    const char *model_path;
    const char *mtp_path;
    zencode_ds4_backend backend;
    int n_threads;
    uint32_t prefill_chunk;
    int mtp_draft_tokens;
    float mtp_margin;
    int power_percent;
    uint32_t ssd_streaming_cache_experts;
    uint64_t ssd_streaming_cache_bytes;
    uint32_t ssd_streaming_preload_experts;
    bool ssd_streaming;
    bool ssd_streaming_cold;
    bool quality;
} zencode_ds4_engine_options;

typedef struct {
    int prompt_tokens;
    int cached_prompt_tokens;
    int evaluated_prompt_tokens;
    int live_tokens_before;
    int common_prefix_tokens;
    int transcript_tokens;
    int session_pos;
    int generated_tokens;
    int finish_reason;
    int effective_think_mode;
    double prompt_seconds;
    double generation_seconds;
    double prompt_tokens_per_second;
    double generation_tokens_per_second;
} zencode_ds4_generation_stats;

typedef struct zencode_ds4_engine zencode_ds4_engine;
typedef struct zencode_ds4_session zencode_ds4_session;

typedef void (*zencode_ds4_emit_fn)(void *user_data, const char *bytes, size_t len);

/*
 * Cooperative cancellation callback. Checked before prompt processing and
 * before sampling each token. Return false to stop generation: the call
 * completes normally with generation_stats.finish_reason == 4 (cancelled).
 */
typedef bool (*zencode_ds4_should_continue_fn)(void *user_data);

int zencode_ds4_engine_open(
    const zencode_ds4_engine_options *options,
    zencode_ds4_engine **out,
    char *error,
    size_t error_len
);

void zencode_ds4_engine_close(zencode_ds4_engine *engine);
const char *zencode_ds4_engine_model_name(zencode_ds4_engine *engine);
zencode_ds4_think_mode zencode_ds4_engine_effective_think_mode(
    zencode_ds4_engine *engine,
    zencode_ds4_think_mode think_mode,
    int ctx_size
);
const char *zencode_ds4_backend_name(zencode_ds4_backend backend);

int zencode_ds4_session_create(
    zencode_ds4_engine *engine,
    int ctx_size,
    zencode_ds4_session **out,
    char *error,
    size_t error_len
);

void zencode_ds4_session_free(zencode_ds4_session *session);
void zencode_ds4_session_reset(zencode_ds4_session *session);
void zencode_ds4_session_append_message(
    zencode_ds4_session *session,
    const char *role,
    const char *content
);
void zencode_ds4_session_append_eos(zencode_ds4_session *session);

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
);

int zencode_ds4_session_transcript_len(zencode_ds4_session *session);
int zencode_ds4_session_pos(zencode_ds4_session *session);
int zencode_ds4_session_ctx(zencode_ds4_session *session);

#ifdef __cplusplus
}
#endif
#endif
