/*
 * zencode_ds4_abi.h - ZenCODE in-process DS4 engine ABI.
 *
 * This header describes the C ABI exported by libzencode-ds4.{dylib,so}, a
 * dynamic library built at setup time from zencode_ds4_shim.c (owned by
 * ZenCODE) compiled against the user's DS4 checkout (ds4.h) and linked with
 * the DS4 Makefile objects.  ZenCODE never links DS4 at compile time: the
 * Swift side mirrors every declaration below with @convention(c) typealiases
 * and resolves each symbol with dlsym().
 *
 * ABI rules
 * - Self-contained: only <stdint.h>, <stddef.h> and <stdbool.h>; it never
 *   includes ds4.h and never shares structs.  Values cross the boundary as C
 *   scalars, `const char *`, opaque `void *` handles and function pointers.
 * - Engine options are an array of "key=value" strings (see
 *   zencode_ds4_engine_open for the supported keys).
 * - Every exported symbol is prefixed `zencode_ds4_`.  Any incompatible
 *   change to a signature, constant or semantic bumps ZENCODE_DS4_ABI_VERSION.
 * - Return codes: 0 is success, positive values are documented non-error
 *   outcomes (interrupted, cancelled, skipped, ...), negative values are the
 *   ZENCODE_DS4_ERR_* errors.  On failure a readable message is available
 *   from zencode_ds4_last_error() and, for calls bound to an engine or a
 *   session, from zencode_ds4_engine_last_error(engine).
 * - The shim never calls exit().  DS4 itself still contains fatal paths
 *   (see "Residual risks" in zencode_ds4_shim.c).
 * - Threading: no function is thread-safe.  Every function is re-entrant
 *   only under caller serialization: the caller must serialize all calls
 *   touching the same engine, its sessions and token buffers (ZenCODE uses
 *   one dedicated thread).  Callbacks run synchronously on the calling
 *   thread and must not call back into this ABI.
 * - Strings returned as `char *` are allocated by the shim and must be
 *   released with zencode_ds4_string_free().  Strings returned as
 *   `const char *` are borrowed; their lifetime is documented per function.
 */
#ifndef ZENCODE_DS4_ABI_H
#define ZENCODE_DS4_ABI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version history
 * 1 - first version.
 * 2 - zencode_ds4_tokens_push (replay of exact token ids). */
#define ZENCODE_DS4_ABI_VERSION 2

#if defined(__GNUC__) || defined(__clang__)
#define ZENCODE_DS4_EXPORT __attribute__((visibility("default")))
#else
#define ZENCODE_DS4_EXPORT
#endif

/* ------------------------------------------------------------------------
 * Return codes
 * --------------------------------------------------------------------- */

#define ZENCODE_DS4_OK 0

/* zencode_ds4_session_sync: the cancel callback interrupted the prefill.
 * Same value as DS4_SESSION_SYNC_INTERRUPTED. */
#define ZENCODE_DS4_SYNC_INTERRUPTED 2

/* zencode_ds4_session_generate outcomes. */
#define ZENCODE_DS4_GENERATE_STOP 0        /* the model produced a stop token */
#define ZENCODE_DS4_GENERATE_MAX_TOKENS 1  /* max_tokens / context room reached */
#define ZENCODE_DS4_GENERATE_CANCELLED 2   /* cancel callback returned non-zero */
#define ZENCODE_DS4_GENERATE_CALLER_STOP 3 /* emit callback returned ZENCODE_DS4_EMIT_STOP */

/* Bit flags returned by zencode_ds4_emit_fn. */
#define ZENCODE_DS4_EMIT_CONTINUE 0 /* keep generating with normal sampling */
#define ZENCODE_DS4_EMIT_STOP 1     /* stop after this token */
#define ZENCODE_DS4_EMIT_GREEDY 2   /* sample the next token greedily */

/* zencode_ds4_session_kv_save: nothing written because the session holds
 * image-conditioned state (never persisted to the text-keyed KV format). */
#define ZENCODE_DS4_KV_SKIPPED_VISION 1

/* Errors (negative). */
#define ZENCODE_DS4_ERR_INVALID_ARGUMENT -1  /* NULL handle, bad value, bad state */
#define ZENCODE_DS4_ERR_OUT_OF_MEMORY -2
#define ZENCODE_DS4_ERR_INVALID_OPTION -3    /* unknown kv key / invalid value / extra_arg */
#define ZENCODE_DS4_ERR_INSTANCE_LOCKED -4   /* DS4 instance lock already held */
#define ZENCODE_DS4_ERR_ENGINE_OPEN -5       /* ds4_engine_open failed (see open log) */
#define ZENCODE_DS4_ERR_SESSION -6           /* session create / sync failure */
#define ZENCODE_DS4_ERR_DECODE -7            /* sampling / eval failure during generate */
#define ZENCODE_DS4_ERR_UNSUPPORTED -8       /* feature not supported by model/backend */
#define ZENCODE_DS4_ERR_VISION -9            /* image decode / encode / append failure */
#define ZENCODE_DS4_ERR_IO -10               /* filesystem error */
#define ZENCODE_DS4_ERR_KV_INVALID -11       /* malformed or truncated KV file */
#define ZENCODE_DS4_ERR_KV_INCOMPATIBLE -12  /* KV file not usable by this engine/session */
#define ZENCODE_DS4_ERR_TENSOR_PARALLEL -13  /* TP leader bring-up failure */
#define ZENCODE_DS4_ERR_BUSY -14             /* engine still has live sessions */

/* ------------------------------------------------------------------------
 * Think modes: same numeric values as ds4_think_mode.  Explicit effort
 * levels are ZENCODE_DS4_THINK_LEVEL_BASE + level (level 0...100).
 * --------------------------------------------------------------------- */

#define ZENCODE_DS4_THINK_NONE 0
#define ZENCODE_DS4_THINK_HIGH 1
#define ZENCODE_DS4_THINK_MAX 2
#define ZENCODE_DS4_THINK_LOW 3
#define ZENCODE_DS4_THINK_MEDIUM 4
#define ZENCODE_DS4_THINK_LEVEL_BASE 1000
#define ZENCODE_DS4_THINK_LEVEL_MAX 100

/* ------------------------------------------------------------------------
 * Tool-call syntax of the loaded model (agent_tool_syntax_for_engine).
 * --------------------------------------------------------------------- */

#define ZENCODE_DS4_TOOL_SYNTAX_DSML 0   /* DeepSeek V4 DSML */
#define ZENCODE_DS4_TOOL_SYNTAX_DSML41 1 /* DeepSeek V4.1 DSML */
#define ZENCODE_DS4_TOOL_SYNTAX_GLM 2    /* GLM <tool_call> */
#define ZENCODE_DS4_TOOL_SYNTAX_QWEN 3   /* Qwen <tool_call> */

/* ------------------------------------------------------------------------
 * Session statistics, read with zencode_ds4_stat().  Values are updated by
 * zencode_ds4_session_sync (prompt/prefill ids, generation ids reset to 0),
 * zencode_ds4_session_generate (generation ids) and
 * zencode_ds4_session_kv_load (prompt ids describe the loaded checkpoint).
 * SESSION_POS and SESSION_CTX are read live.
 * --------------------------------------------------------------------- */

#define ZENCODE_DS4_STAT_PROMPT_TOKENS 0             /* tokens in the last synced prompt */
#define ZENCODE_DS4_STAT_CACHED_TOKENS 1             /* prompt tokens reused from the live KV */
#define ZENCODE_DS4_STAT_EVALUATED_TOKENS 2          /* prompt suffix evaluated by the last sync */
#define ZENCODE_DS4_STAT_GENERATED_TOKENS 3          /* tokens emitted by the last generate */
#define ZENCODE_DS4_STAT_PREFILL_SECONDS 4
#define ZENCODE_DS4_STAT_GENERATION_SECONDS 5
#define ZENCODE_DS4_STAT_PREFILL_TOKENS_PER_SECOND 6
#define ZENCODE_DS4_STAT_GENERATION_TOKENS_PER_SECOND 7
#define ZENCODE_DS4_STAT_SESSION_POS 8
#define ZENCODE_DS4_STAT_SESSION_CTX 9
#define ZENCODE_DS4_STAT_COUNT 10

/* ------------------------------------------------------------------------
 * Callbacks
 * --------------------------------------------------------------------- */

/* Prefill progress (both durable and display-only DS4 progress events are
 * forwarded).  `event` is a borrowed DS4 event name valid only during the
 * call; while waiting for a distributed route the shim reports the event
 * "distributed_route_wait" with current = elapsed polls and total = 0.
 * zencode_ds4_session_sync first reports the shim's own event "prefill_start"
 * with current = reused (cached) prefix length and total = prompt tokens, once
 * per sync before any evaluation (also when no suffix is left to evaluate).
 * The DS4 "prefill_*" events that follow carry absolute positions on most
 * paths. */
typedef void (*zencode_ds4_progress_fn)(void *ud, const char *event, int current, int total);

/* Cooperative cancellation: return non-zero to cancel. */
typedef int (*zencode_ds4_cancel_fn)(void *ud);

/* Called once per committed generated token with its `len` raw bytes
 * (ds4_token_text; not NUL-terminated, may split a UTF-8 sequence across
 * calls, valid only during the call).  Returns ZENCODE_DS4_EMIT_* bit flags:
 * EMIT_STOP ends generation after this token; EMIT_GREEDY makes the next
 * sampling step greedy (temperature 0, top_p 1, min_p 0) and holds only
 * while it keeps being returned. */
typedef int (*zencode_ds4_emit_fn)(void *ud, const char *bytes, size_t len);

/* ------------------------------------------------------------------------
 * Library
 * --------------------------------------------------------------------- */

/* Returns ZENCODE_DS4_ABI_VERSION of the compiled shim.  The caller must
 * refuse the library when it differs from the version it was built for. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_abi_version(void);

/* Message of the most recent failed call on the calling thread ("" when none).
 * Cleared at the start of every fallible call.  Borrowed: valid until the
 * next call on the same thread.  Never NULL. */
ZENCODE_DS4_EXPORT const char *zencode_ds4_last_error(void);

/* Releases a string returned as `char *` by this ABI.  NULL is a no-op. */
ZENCODE_DS4_EXPORT void zencode_ds4_string_free(char *s);

/* Full DS4 stderr output captured during the most recent
 * zencode_ds4_engine_open call (success or failure; the tail is kept when it
 * exceeds 256 KiB).  Borrowed: valid until the next engine_open.  Never NULL. */
ZENCODE_DS4_EXPORT const char *zencode_ds4_engine_open_log(void);

/* Parses an explicit think effort "0".."100" (ds4_think_mode_parse_level).
 * Returns ZENCODE_DS4_THINK_LEVEL_BASE + level, or ZENCODE_DS4_ERR_INVALID_ARGUMENT. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_think_mode_parse_level(const char *text);

/* Effective think mode for a context size (ds4_think_mode_for_context): MAX
 * degrades to HIGH below the model's minimum context.  Depends on the model
 * family selected by the last engine_open.  Returns the mode, or
 * ZENCODE_DS4_ERR_INVALID_ARGUMENT for an unknown mode value. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_think_mode_for_context(int32_t think_mode, int32_t ctx_size);

/* ------------------------------------------------------------------------
 * Engine
 * --------------------------------------------------------------------- */

/* Opens the model.  `kv` holds `kv_count` "key=value" strings (copied; the
 * caller keeps ownership).  Unknown keys, duplicated keys (except extra_arg),
 * missing '=' and invalid values fail with ZENCODE_DS4_ERR_INVALID_OPTION.
 *
 * Keys (defaults follow ds4-agent parse_options):
 *   ds4_root=<abs dir>          DS4 checkout; exports DS4_METAL_<STEM>_SOURCE
 *                               for every <root>/metal/<stem>.metal (existing
 *                               user overrides are kept).  Required for the
 *                               Metal backend unless the process cwd is the
 *                               DS4 root or every override is already set.
 *   model_path=<path>           required.  Paths are used verbatim: pass
 *                               absolute paths (relative ones resolve against
 *                               the process cwd, not ds4_root).
 *   mtp_path=<path>             MTP / DSpark support GGUF.
 *   vision_path=<path>          vision projector GGUF.
 *   backend=metal|cuda|cpu|rocm default metal on macOS, cpu for DS4_NO_GPU
 *                               builds, cuda otherwise; rocm maps to the CUDA
 *                               backend id (ROCm builds of ds4-agent).
 *   n_threads=<int > 0>
 *   context_size=<int > 0>      also sets placement_ctx_hint.
 *   session_count=<int > 0>     placement_session_count_hint.
 *   prefill_chunk=<int > 0>
 *   mtp_draft_tokens=<int > 0>  default 1.
 *   mtp_margin=<0..1000>        default 3.0.
 *   glm_mtp=<bool>              (--mtp)
 *   dspark=<bool>
 *   dspark_strict=<bool>        true also enables dspark.
 *   dspark_exact_sampling=<bool> (--mtp-exact-sampling)
 *   dspark_confidence_threshold=<0..1>  also enables dspark.
 *   power_percent=<1..100>
 *   quality=<bool>
 *   warm_weights=<bool>
 *   ssd_streaming=<bool>
 *   ssd_streaming_cold=<bool>
 *   ssd_streaming_cache_experts=<count>|<N>GB
 *   ssd_streaming_full_layers=<int >= 0>
 *   ssd_streaming_preload_experts=<int > 0>
 *   directional_steering_file=<path>   ffn scale defaults to 1.0 when no
 *                               directional_steering_ffn/attn key is given.
 *   directional_steering_ffn=<-100..100>
 *   directional_steering_attn=<-100..100>
 *   extra_arg=<token>           repeatable; the tokens, in order, form an argv
 *                               parsed like ds4-agent: distributed options
 *                               (--role, --layers, --listen, --coordinator,
 *                               --dist-*, --debug), tensor-parallel options
 *                               (--tensor-parallel, --transport, --rdma-*,
 *                               --tensor-parallel-token-prefill,
 *                               --debug-hash), --gpu-vram, --gpu-devices and
 *                               --cuda-tensor-parallel.  Any other token fails.
 *                               Worker roles are rejected (serving modes).
 * <bool> is one of 1, 0, true, false, yes, no.
 *
 * Before ds4_engine_open the shim checks that model_path, mtp_path and
 * vision_path open as regular files of at least 32 bytes (DS4 exit(1)s
 * otherwise) and checks the DS4 instance lock
 * ($DS4_LOCK_FILE, default /tmp/ds4.lock) because DS4 calls exit(2) when it
 * is held: a held lock returns ZENCODE_DS4_ERR_INSTANCE_LOCKED ("another ds4
 * process is already running (pid N)"; this includes an engine already open
 * in this process).  A small race remains between this check and DS4's own
 * flock.
 *
 * DS4 stderr (fd 2) is captured during the call: the last non-empty lines
 * are appended to the error message and the full text is available from
 * zencode_ds4_engine_open_log().  fd 2 is process-wide, so output written by
 * other threads during the call is captured too.
 *
 * With a tensor-parallel leader configuration the call also creates the TP
 * transport and binds it (blocking until the worker connects), like
 * ds4-agent.  The TP / distributed paths are not verifiable in ZenCODE's
 * test environment.
 *
 * On success stores the engine handle in *out_engine and returns 0.  On
 * failure *out_engine is NULL. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_open(const char *const *kv, size_t kv_count,
                                                   void **out_engine);

/* Closes the engine (stops the TP leader transport, releases the DS4
 * instance lock).  Returns ZENCODE_DS4_ERR_BUSY, without closing, while
 * sessions created from it are still alive.  NULL returns 0. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_close(void *engine);

/* Message of the most recent failed call bound to this engine or to one of
 * its sessions ("" when none).  Borrowed: valid until the next call on the
 * engine.  Never NULL (a NULL engine returns zencode_ds4_last_error()). */
ZENCODE_DS4_EXPORT const char *zencode_ds4_engine_last_error(void *engine);

/* Model name.  Borrowed: valid until engine_close.  Never NULL. */
ZENCODE_DS4_EXPORT const char *zencode_ds4_engine_model_name(void *engine);

/* Stable KV-compatibility model id (ds4_engine_model_id), or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_model_id(void *engine);

/* Routed-expert quantization bits (ds4_engine_routed_quant_bits), or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_routed_quant_bits(void *engine);

/* 1 when a vision projector is loaded, 0 otherwise, negative on error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_has_vision(void *engine);

/* ZENCODE_DS4_TOOL_SYNTAX_* of the loaded model, or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_tool_syntax(void *engine);

/* Effective MTP draft tokens (1 = no speculative decoding), or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_engine_mtp_draft_tokens(void *engine);

/* ------------------------------------------------------------------------
 * Token buffers
 *
 * A token buffer is an opaque, growable token sequence that also owns the
 * vision spans appended by zencode_ds4_chat_append_multimodal_message.  All
 * chat_* functions append to the buffer (chat_begin included: start from a
 * fresh buffer).  A buffer is engine-independent storage, but its token ids
 * are only meaningful for the engine that produced them.
 * --------------------------------------------------------------------- */

/* New empty buffer, or NULL on allocation failure.  Free with tokens_free. */
ZENCODE_DS4_EXPORT void *zencode_ds4_tokens_new(void);

/* Frees the buffer and the image embeddings owned by its vision spans.
 * NULL is a no-op. */
ZENCODE_DS4_EXPORT void zencode_ds4_tokens_free(void *tokens);

/* Number of tokens, or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokens_len(void *tokens);

/* Token id at `index`, or ZENCODE_DS4_ERR_INVALID_ARGUMENT when out of range. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokens_get(void *tokens, int32_t index);

/* Number of vision spans (images) owned by the buffer, or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokens_image_count(void *tokens);

/* New buffer holding a copy of the tokens of `src`, or NULL on error.
 * Buffers holding images cannot be copied (ZENCODE_DS4_ERR_UNSUPPORTED via
 * last_error) because image embeddings are uniquely owned. */
ZENCODE_DS4_EXPORT void *zencode_ds4_tokens_copy(void *src);

/* Appends one token id as is (ds4_tokens_push), without tokenizing anything:
 * how a caller replays the exact ids a previous session_generate committed
 * (see session_transcript_append_to), so that re-tokenizing the generated text
 * cannot produce a different split than the one that was sampled and the live
 * KV keeps being a common prefix of the next prompt.  The id is not checked
 * against the vocabulary of any engine: the caller must only replay ids of the
 * engine that produced them.  Returns 0, or ZENCODE_DS4_ERR_INVALID_ARGUMENT
 * when `tokens` is NULL or `token` is negative. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokens_push(void *tokens, int32_t token);

/* Appends the model's BOS/chat-start sequence (ds4_chat_begin). */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_chat_begin(void *engine, void *tokens);

/* Appends one rendered chat message (ds4_chat_append_message).  `role` is a
 * DS4 role ("system", "user", "assistant", "tool"); content may be "". */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_chat_append_message(void *engine, void *tokens,
                                                           const char *role,
                                                           const char *content);

/* Appends the think prefix for `think_mode` (ds4_chat_append_think_prefix).
 * Explicit effort levels require a DeepSeek V4.1 model (as in ds4-agent). */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_chat_append_think_prefix(void *engine, void *tokens,
                                                                int32_t think_mode);

/* Appends the assistant turn prefix (ds4_chat_append_assistant_prefix).
 * Explicit effort levels require a DeepSeek V4.1 model. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_chat_append_assistant_prefix(void *engine, void *tokens,
                                                                    int32_t think_mode);

/* Appends the tokenization of already rendered chat text, special tokens
 * included (ds4_tokenize_rendered_chat). */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokenize_rendered_chat(void *engine, void *tokens,
                                                              const char *text);

/* Appends the EOS / end-of-turn token (ds4_token_eos). */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_tokens_push_eos(void *engine, void *tokens);

/* Renders the tokens back to text (ds4_kvstore_render_tokens_text).
 * Returns a NUL-terminated string (embedded NULs possible; use *out_len,
 * which may be NULL) to release with zencode_ds4_string_free, or NULL on error. */
ZENCODE_DS4_EXPORT char *zencode_ds4_render_tokens_text(void *engine, void *tokens,
                                                        size_t *out_len);

/* ------------------------------------------------------------------------
 * Vision
 * --------------------------------------------------------------------- */

/* Decodes and encodes an image file (ds4_engine_vision_encode_file).
 * Returns an opaque embedding handle, or NULL on error
 * (ZENCODE_DS4_ERR_UNSUPPORTED without a vision projector,
 * ZENCODE_DS4_ERR_VISION otherwise; see last_error).  The caller always
 * releases the handle with zencode_ds4_vision_embedding_free. */
ZENCODE_DS4_EXPORT void *zencode_ds4_engine_vision_encode_file(void *engine, const char *path);

/* Releases an embedding handle (and its data if still owned).  NULL is a no-op. */
ZENCODE_DS4_EXPORT void zencode_ds4_vision_embedding_free(void *embedding);

/* Appends a user or tool message whose `n_parts` text parts alternate with
 * `n_images` images (ds4_chat_append_multimodal_message); n_parts must be
 * n_images + 1 and NULL text parts count as "".  On success the embedding
 * data moves into the buffer's vision spans: the handles become empty (they
 * cannot be appended again) but must still be released with
 * zencode_ds4_vision_embedding_free.  On failure nothing is appended and the
 * handles keep their data. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_chat_append_multimodal_message(
        void *engine, void *tokens, const char *role,
        const char *const *text_parts, size_t n_parts,
        void *const *embeddings, size_t n_images);

/* ------------------------------------------------------------------------
 * Sessions
 *
 * A session owns the live KV cache plus a transcript: the tokens of the
 * last successful sync (or KV load) followed by every token emitted by
 * session_generate.
 * --------------------------------------------------------------------- */

/* Creates a session with `ctx_size` tokens of context (ds4_session_create;
 * DS4 stderr is captured into the error message).  Stores the handle in
 * *out_session and returns 0. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_create(void *engine, int32_t ctx_size,
                                                      void **out_session);

/* Frees the session.  NULL is a no-op. */
ZENCODE_DS4_EXPORT void zencode_ds4_session_free(void *session);

/* Waits until a distributed coordinator has full layer coverage
 * (ds4_session_distributed_route_ready polled every 250 ms, as ds4-agent).
 * Returns 0 immediately for non-distributed engines, ZENCODE_DS4_SYNC_INTERRUPTED
 * when `cancel` returns non-zero, or ZENCODE_DS4_ERR_SESSION.  session_sync
 * calls it implicitly; call it explicitly before session_kv_load. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_wait_distributed_route(
        void *session, zencode_ds4_progress_fn progress, zencode_ds4_cancel_fn cancel, void *ud);

/* Synchronizes the live KV to the full prompt in `tokens`: computes the
 * reusable prefix (ds4_session_common_prefix), then runs ds4_session_sync, or
 * ds4_session_sync_multimodal when the buffer holds images.  progress/cancel
 * (both optional) are installed for the duration of the call; progress first
 * receives "prefill_start" (current = reused prefix, total = prompt tokens).
 * *out_cached / *out_suffix (optional) receive the reused prefix length and
 * the evaluated suffix length (also on interruption).
 * Returns 0, ZENCODE_DS4_SYNC_INTERRUPTED (the live KV may hold only a
 * prefix; sync again before generating), or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_sync(void *session, void *tokens,
                                                    zencode_ds4_progress_fn progress,
                                                    zencode_ds4_cancel_fn cancel, void *ud,
                                                    int32_t *out_cached, int32_t *out_suffix);

/* Live position (tokens in the KV), or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_pos(void *session);

/* Context size, or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_ctx(void *session);

/* Changes the power percentage (1...100) for future evaluation
 * (ds4_session_set_power).  Unsupported models return
 * ZENCODE_DS4_ERR_UNSUPPORTED with the DS4 reason. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_set_power(void *session, int32_t power_percent);

/* Changes the directional-steering FFN scale (-100...100) for future
 * evaluation (ds4_session_set_directional_steering_ffn).  Requires a steering
 * file loaded at engine_open and a non-distributed session. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_set_directional_steering_ffn(void *session,
                                                                            double scale);

/* Generates up to `max_tokens` tokens (clamped to ctx - pos - 1) after a
 * successful session_sync or kv_load, replicating the ds4-agent assistant
 * loop (ds4_agent.c generation round):
 * - ds4_session_sample (greedy while the previous emit returned
 *   ZENCODE_DS4_EMIT_GREEDY; the first step samples normally);
 * - ds4_session_eval_speculative when ds4_engine_mtp_draft_tokens > 1
 *   (unless DS4_MTP_SPEC_DISABLE is set), otherwise ds4_session_eval;
 * - ds4_token_is_stop_for_think_mode(think_mode) ends generation, rewinding
 *   speculative overshoot (ds4_session_rewind);
 * - every committed token is appended to the session transcript and passed
 *   to `emit` (optional); EMIT_STOP rewinds the rest of the speculative
 *   block; with exact MTP sampling, temperature > 0 and a greedy-mode change
 *   inside a speculative block the session rewinds to the token, re-evaluates
 *   it and samples again under the new mode (a rewind that needs a full
 *   rebuild of an image-conditioned session fails with
 *   ZENCODE_DS4_ERR_UNSUPPORTED: sync again).
 * `cancel` (optional) is polled before each sampling step.  seed 0 selects a
 * random seed.  think_mode is a ZENCODE_DS4_THINK_* value (explicit levels
 * require DeepSeek V4.1).  top_k 0 disables top-k.
 * Returns ZENCODE_DS4_GENERATE_STOP, _MAX_TOKENS, _CANCELLED, _CALLER_STOP, or a
 * negative error (tokens emitted before the error stay in the transcript).
 * The stop token itself is never emitted nor appended.
 * The tokens this call appends to the session transcript are exactly the
 * committed ones, in order, and each was passed to `emit`: no stop token, and
 * none of the speculative tokens rewound after a stop or EMIT_STOP.  Read them
 * with session_transcript_len before the call (start) and
 * session_transcript_append_to(start) after it. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_generate(void *session, int32_t max_tokens,
                                                        int32_t think_mode, double temperature,
                                                        int32_t top_k, double top_p, double min_p,
                                                        uint64_t seed, zencode_ds4_emit_fn emit,
                                                        zencode_ds4_cancel_fn cancel, void *ud);

/* Statistic ZENCODE_DS4_STAT_*; -1.0 for an unknown id or a NULL session. */
ZENCODE_DS4_EXPORT double zencode_ds4_stat(void *session, int32_t stat_id);

/* Transcript length, or a negative error (0 before the first sync). */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_transcript_len(void *session);

/* Appends transcript tokens [start, transcript_len) to `dst` (for example
 * the tokens produced by the last generate, so the caller's buffer keeps the
 * exact token history and its images).  Returns the number of appended
 * tokens or a negative error. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_transcript_append_to(void *session, int32_t start,
                                                                    void *dst);

/* ------------------------------------------------------------------------
 * Disk KV checkpoints (ds4_kvstore file format, as ds4-agent):
 *   48-byte ds4_kvstore header (model_id, routed quant bits, reason
 *   "agent-session", tokens, ctx, payload bytes, ext flags)
 *   u32 LE text length + text rendered from the live tokens
 *   staged DS4 session payload
 *   [optional trailer: u32 LE length + bytes, ext flag SESSION_TITLE]
 * --------------------------------------------------------------------- */

/* Saves the live KV to `path` atomically (temporary file in the same
 * directory + rename).  `trailer` / `trailer_len` is optional opaque caller
 * data (for example a session title or JSON metadata) stored after the
 * payload; NULL writes no trailer.  The live tokens must match the session
 * transcript.  Returns 0, ZENCODE_DS4_KV_SKIPPED_VISION (nothing written),
 * or a negative error.  DS4 stderr is captured into the error message. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_kv_save(void *session, const char *path,
                                                       const char *trailer, size_t trailer_len);

/* Loads `path` into the session.  Validates the header, model id, routed
 * quant bits and context (header ctx <= session ctx, tokens < session ctx),
 * loads the payload (or, for an empty payload or a TP leader, rebuilds by
 * re-tokenizing the stored text and syncing without progress, as
 * ds4-agent), checks the token count, then verifies that the stored text is
 * byte-identical to the rendering of the loaded tokens and that its
 * re-tokenization shares a non-empty prefix with them.  Any mismatch returns
 * ZENCODE_DS4_ERR_KV_INCOMPATIBLE; once the payload load (or rebuild) has
 * started, a failure also invalidates the session (sync again).  A malformed
 * file returns ZENCODE_DS4_ERR_KV_INVALID.  On success the transcript becomes
 * the loaded tokens, and when the file has a trailer *out_trailer receives a
 * NUL-terminated copy (release with zencode_ds4_string_free) and
 * *out_trailer_len its length; otherwise *out_trailer is NULL and the
 * length 0.  Both out parameters are optional. */
ZENCODE_DS4_EXPORT int32_t zencode_ds4_session_kv_load(void *session, const char *path,
                                                       char **out_trailer,
                                                       size_t *out_trailer_len);

#ifdef __cplusplus
}
#endif

#endif /* ZENCODE_DS4_ABI_H */
