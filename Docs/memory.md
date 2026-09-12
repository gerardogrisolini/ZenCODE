# Memory Ownership and Persistence

This guide is part of the compatibility contract in
[architecture.md](architecture.md): the rules below are authoritative for
durable memory storage, retrieval, embedding, recall, and persisted formats.

Project memory is owned by the internal `ZenMemory` engine at
`Sources/ZenCODECore/ZenCODE/Memory/Engine`; ZenCODECore's public `Memory`
domain is a thin async facade over it (`MemoryService` →
`MemoryGraphStore` → `ZenMemory` actor). The authoritative store is the
per-workspace graph file at
`<supportDirectory>/memory/<sha256(workspacePath)>/memory.graph.json`, where
`<sha256(workspacePath)>` is the full SHA256 hex digest of the standardized
workspace path and `<supportDirectory>` honours `ZENCODE_SUPPORT_DIRECTORY`
(default `~/.zencode`). The graph is written atomically as sorted-key
pretty-printed JSON and is deliberately kept out of the workspace working tree
because it may embed float vectors. A process-wide `MemoryGraphStoreRegistry`
caches one open store per graph URL so parallel tool executions share a single
engine instance.

Opening loads only the JSON graph, or starts with an empty graph if no JSON
file exists. `open` never persists: a cold `memory.search` / `memory.read`
neither creates the graph file nor requires a writable support directory.
The first mutation atomically persists the graph. An existing `MEMORY.md`,
whether valid, malformed or unreadable, is completely ignored: it is not
read, parsed, imported, embedded, rewritten or deleted. Its contents cannot
influence memory reads, searches or automatic recall. Previously persisted
JSON graph entries remain available; JSON version compatibility is unchanged.
The file-specific template, filename constant and document errors are removed;
the deprecated synchronous APIs that operate on the graph remain supported.

Every mutation — `write`, `update`, `archive`, `delete` — runs through the
engine's transaction primitive
(`ZenMemory.transaction(_:)`), which commits after save: the body mutates a
private draft of the graph, the draft is persisted first, and it becomes the
live graph only when the save succeeded. A throwing body or a failed save
therefore changes nothing — the in-memory graph stays exactly as it was instead
of silently diverging from disk — and a body that left the graph unchanged never
touches disk. The transaction also serializes read-modify-write sequences that
would otherwise interleave across actor suspension points, and it re-checks
`Task.checkCancellation()` after the write lock is acquired and before the
body/save: a task cancelled while parked at the lock neither commits nor
strands the lock. The graph JSON carries `graph_version` (currently 2); a file
written by a newer engine is rejected on load and left byte-identical, while
older files decode through optional fields with contract defaults (`scope` →
`.project`, `active` → `true`, …). A file with no `graph_version` key at all is
the legacy v1 format (`MemoryGraph.legacyGraphVersion`): it is decoded with the
same contract defaults and normalized to the current version in memory. Loading
never rewrites the file — the on-disk graph stays byte-identical until an
explicit save (a mutation) writes the current version.

ZenCODECore exposes its own public DTOs (`MemoryEntry`, `MemoryScope`,
`MemoryCategory`) declared under `ZenCODE/Models`; the internal `ZenMemory`
engine implementation stays behind the facade (internal aliases bridge the two).
The facade API is async first: `MemoryService`'s
primary methods (`readEntries`, `searchEntries`, `entry`, `writeEntry`,
`updateEntry`, `archiveEntry`, `setArchived`, `deleteEntry`) are `async throws`
and keyed by `workspaceRootURL:`. The modern tool entry point is
`MemoryTool.executeAsync(_:context:memoryService:)`; it was renamed from
`execute` so the legacy synchronous `execute` — the exact 1.1.x spelling — is
the only `execute` overload and `try MemoryTool.execute(…)` compiles unchanged
from both sync and async call sites. The pre-graph 1.1.x synchronous surface
survives as deprecated wrappers (`MemoryLegacyCompatibility.swift`) that keep
the old `scope:` / `workingDirectory:` labels and block the calling thread
through a deadlock-safe bridge (from both sync and async call sites) with
read/mutation-split timeout semantics: a
legacy read uses a bounded wait (60 s) and may be abandoned on timeout — a
late read result is harmless because reads have no durable side-effect — while
a legacy mutation never reports "abandoned": if the bounded wait expires the
bridge keeps waiting for the definitive outcome without cancelling, so a commit
is never reported as abandoned. Moving to the async API means renaming the
labels to `workspaceRootURL:` and adding `try await`. The legacy nil-directory semantics
are preserved on the wrappers: reads return `[]` (the 1.1.x behaviour), while
mutations throw `scopeUnavailable`; the modern async API is uniformly throwing —
a nil `workspaceRootURL` fails with `scopeUnavailable` for reads and mutations
alike. `scope` is accepted on the wrappers for source compatibility and only
`.project` is backed by a per-workspace graph. Retrieval
is BM25-first: `ZenMemory.recall` always runs lexical retrieval through the
pluggable `MemoryIndex` protocol (default `BM25MemoryIndex`) and uses those hits
as seeds, then a breadth-first relation cascade with depth decay and
per-retrieval confidence boost/decay. `memory.search` is strictly read-only: the
store's `search` runs the engine's `searchReadOnly` path, which shares the same
analyze → retrieve → select pipeline as recall but performs no transactional
maintenance — it never mutates `retrievalCount`/`confidence`/links and cannot
fail on a save error — while automatic recall (`context(for:)`) keeps its
maintenance-bearing path unchanged. Automatic recall revalidates before it
commits: the maintenance transaction re-checks the retrieved candidates and
the selected set against the current graph draft, dropping any entry a
concurrent forget/archive/scope change made stale while the selector was
awaiting, and co-relevance linking only ever connects live endpoints (linking
a missing or inactive node is a no-op), so no dangling edges are persisted and
the returned result never contains eliminated entries. Without an embedder,
BM25 is the sole seed source; reciprocal-rank fusion is applied only when an
embedder is configured, merging the semantic and lexical rankings before the
cascade.

Embeddings are opt-in and off by default. With no provider configured, entries
carry no vector and retrieval is pure BM25 plus graph expansion. The persisted
settings manifest (`AgentMemoryEmbeddingSettingsManifest`, manifest version 12,
`settings.json` `memoryEmbedding`) stores a normalized absolute HTTP(S)
endpoint — plus, optionally, an OpenAI-compatible `model` identifier and a
non-secret `providerID` reference to a configured provider whose API key the
resolver reuses at runtime. Legacy v11 endpoint-only values decode unchanged
(`model`/`providerID` nil) and re-encode byte-identically. Setup configures it
interactively ("Memory embeddings": BM25 only / add / change / remove endpoint,
detail line "BM25 only" or the stored endpoint, with the model appended when
present). When at least one configured provider is OpenRouter, setup proposes an
OpenRouter choice immediately, precompiled to the canonical endpoint
`https://openrouter.ai/api/v1/embeddings` with model `qwen/qwen3-embedding-8b`
and the referenced provider's ID; without an OpenRouter provider no such
proposal appears. The manual add/change-endpoint path stays endpoint-only by
design: it never carries over the preset's model/provider reference, so an
edited endpoint cannot silently reuse the provider's key. Setup validates the
URL format entirely locally: it never
probes the endpoint, never enumerates models, and never asks for credentials.
The embedding request never duplicates the provider's API key: when
`providerID` is set the resolver reads
`remoteAPIKeysByProviderID[providerID.uuidString.lowercased()]` at runtime only
if the reference resolves to a configured OpenRouter provider **and** the
embedding endpoint is itself an OpenRouter endpoint; any mismatch (custom or
legacy endpoint-only setups, a stale `providerID`, an endpoint on a different
host) sends the request without Authorization, so a manipulated `settings.json`
can never forward an OpenRouter key to an arbitrary host. For compatibility,
the legacy environment variable
`ZENCODE_MEMORY_EMBEDDING_ENDPOINT` is still honoured as a fallback when the
manifest field is absent (i.e. a legacy v10 install that never went through
setup); an explicitly disabled manifest suppresses it. `MemoryEmbedding.provider(...)`
resolves task-local override first, then manifest endpoint or disabled, then
environment only when the manifest field is absent, then BM25. The endpoint
identifies the embedding model itself: `OpenAICompatibleEmbeddingProvider` derives a stable
endpoint-hash `modelID` when none is supplied and deliberately omits `model`
from the request body, so an endpoint-only server chooses; a stored `model` is
sent in the request body instead. The engine still
ships `DeterministicHashEmbeddingProvider` (a 128-dimension signed feature-hashing
bag-of-words encoder, not a semantic model), but it is no longer wired in by
default. Entries record their `embeddingModel`, so a provider change degrades to
lexical retrieval instead of returning wrong matches. Provider resolution sits
behind a task-local seam (`MemoryEmbedding.withProvider(_:operation:)`). Under
a test harness the real process environment is never consulted: resolution
returns no provider — and makes no network call — unless a test explicitly
binds one through the seam, so memory tests stay hermetic even when the
developer's shell exports `ZENCODE_MEMORY_EMBEDDING_ENDPOINT`.

Automatic recall is on by default and adds no second LLM call. Before every
turn — operator and delegated sub-agent alike — `MemoryTurnCoordinator`
resolves the workspace graph and runs the store's `context(for:scope:)`
inline: offline BM25 seeds, graph expansion, and selection through
`ScoreThresholdMemorySelector`. Without an endpoint, retrieval is local BM25
and costs no extra round trip; with an endpoint, a bounded HTTP call to the
embedding service adds semantic similarity and fusion. Neither adds a second
LLM call — what reaches the wire is the formatted block, which
does add input tokens to the outgoing request and is therefore bounded by a
character budget (`ZENCODE_MEMORY_RECALL_MAX_CHARACTERS`, default 4 000
characters, clamped to [200, 32 000]; ZenCODE counts roughly four characters
per token, so the default is about 1k tokens of recalled memory). The whole
pipeline, including the one-time JSON graph open on a cold workspace,
is bounded by `ZENCODE_MEMORY_RECALL_TIMEOUT_MS` (default
150 ms, clamped to [10, 5000]). When an embedding provider is configured,
`MemoryTurnCoordinator` prepares a maintenance-free local BM25 result alongside
the full semantic recall. A semantic result completed within the deadline wins;
if the endpoint is still pending, the prepared lexical block is injected instead
and the losing request is cancelled without being awaited. If the graph cannot
open or the local fallback itself is not ready at the deadline, recall resolves
to no block, which makes the outgoing request byte-identical to one sent with
memory switched off. A session is auto-disabled after three consecutive
unusable attempts; a delivered lexical fallback counts as a success, any other
success resets the counter, and closing or resetting a session discards its
state.

The engine's N→N+1 `submitContext(_:)` / `takePending()` pipeline is
deliberately not used. `ZenMemory.pending` is a single unkeyed array on the
engine actor, while `MemoryGraphStoreRegistry` caches exactly one store — and
so one engine — per workspace graph URL, shared by every concurrent session,
sub-agent, and tool call in that workspace. A wholesale drain would hand one
session the memories retrieved for another's prompt; inline per-prompt
retrieval keeps every recall bound to the prompt that asked for it.

The block travels out-of-band through
`MemoryTurnContext.currentTurnMemoryBlock`, a task-local bound around
`sendPrompt`. The embedding provider is the single fixed provider resolved from
setup for the workspace store; it is independent of the destination chat model
or provider. Operator turns and delegated agents using GLM, Claude, GPT, or any
other configured model query the same memory graph through that embedder, then
receive only the selected memory text. Switching the chat backend neither
re-embeds nor duplicates durable entries. At request assembly,
`RemoteGenerationClient.applyingCurrentTurnMemory(to:)` merges the block into the
outgoing copy of the last user message — the single shared injection point for
all three concrete generation clients, so the wire formats cannot drift.
Callers apply it on every tool round against the fresh value of
`session.messages`, so each round's outgoing copy carries the block exactly
once. `session.messages` is never mutated, so the block never enters
conversation history, saved-session snapshots, or the session cache key;
saved-session and prompt-cache compatibility are preserved. The alternatives
were rejected on purpose: `systemPrompt` participates in the session cache
key, and `dynamicContext` is compared by
`matchesSessionIdentityIgnoringThinking`, so either would rotate the cache key
or force a `createSession` on every turn.

The block is an explicitly labelled container (`<project-memory>` …
`</project-memory>`) so the model reads it as background context, not as text
the user just typed. Two properties are enforced when it is built: recalled
content is escaped so no `project-memory` tag inside an entry can close the
container (both the `<project-memory` and `</project-memory` spellings are
rewritten to `&lt;project-memory` / `&lt;/project-memory`, case-insensitively,
leaving code otherwise untouched), and the payload is
truncated to the recall character budget on line boundaries, appending a
truncation notice when the selection did not fit. The fixed header, the tags
and the notice are constant overhead on top of the budgeted payload.

The main model owns durable memory explicitly through the five `memory.*` tools
— `memory.read`, `memory.search`, `memory.write`, `memory.update`,
`memory.archive` — guided by `MemoryService.toolUsagePromptSection()` (search
before writing, update instead of duplicating, archive stale entries, prefer
fresh evidence over memory). `MemoryTurnCoordinator` drives recall only, and
`MemoryTurnCoordinator.discard(sessionID:)` drops only per-session recall health
state on close/reset/rebuild. The engine's `learn(from:)`, its default
`NoopMemoryExtractor` (which extracts nothing), and its LLM-backed extractor
stay unwired internals of `ZenMemory`. Selective product consolidation instead
uses the runner-owned same-backend path described below; opening a store alone
still never performs an extraction request.

## Conservative project-memory consolidation

`AgentCoreSessionRunner` is the sole automatic writer owner. After a successful
root turn, while retaining the turn lease, `MemoryLearningLedger` offers a bounded
**new tool-evidence delta**, not the conversation. Delegated runtimes do not run
independent extractors; their summaries and task `succeeded` / `validatedAt`
(including empty evidence) are not proof and are not imported into this ledger.
Cancelled/failed turns and unresolved failures do not consolidate. Existing manual
`memory.*` semantics and all public protocols/JSON formats remain unchanged.

The initial, intentionally narrow evidence adapters recognize correlated
`local.editFile`, `local.multiEdit`, `local.writeFile`, bounded `local.readFile`,
and `swift.test` / `swift.build` results. A substantive explicit-decision cue in
the current user prompt plus an observed project file can trigger a decision
proposal without an error or test. There is no mandatory user prefix: English
and Italian cue fragments only limit calls; the model must judge actual explicit
project intent. An anaphoric “yes” is insufficient. Other facts require a file
correction and a later verification. Ordinary conversation, assistant claims,
thoughts, task completion, recalled notes, and generic operational preferences
are never evidence. Only an explicit allowlist of known read-only observations
can be ignored safely; other commands (including `local.exec`, `swift.run`,
`swift.package` and pathless `local.applyPatch`) invalidate the delta rather than
leaving an earlier verification apparently current. Later failures, even uncited
or differently scoped, cannot be hidden behind an old pass; every observed failing
invocation needs a later matching pass. Uninterpretable/out-of-root verification
fails closed. Only same-turn chains are supported initially. Root and evidence
paths resolve symlinks before containment checks; both alias and target paths are
screened for sensitivity. This is not protection against concurrent filesystem
symlink replacement between tool execution and evidence observation.

A lesson must cite an observed failure, a supported cause from file/correction
evidence, an identified correction, a later relevant successful verification,
and prevention mentioning the actual project path. Runtime checks citation
existence, kind, ordering, bounds, and identical failing/passing invocation and
workspace scope. Test metadata is parsed only from the structured header and
requires explicit non-timeout/non-truncation flags; raw tails are discarded.
Build summaries lack completeness metadata, so **only invocation/status** is
retained: build diagnostics cannot establish a cause. Causal explanation, actual
project-decision intent, and verification relevance to the correction remain model
judgments, **not automatically proven correctness**. No candidate is a normal
outcome; there is no quota to fill. Unsupported tools/projects may yield no
learning even after useful work.

Eligible events use one additional request (with cost and latency) through the
already active `AgentCoreBackend` / `AgentRuntimeBackend`, reusing its provider,
model and compatible generation/thinking settings, never resolving a new provider
or credentials. The ephemeral session has empty history, no user cache key, no
recall, no runner snapshot/seed/skill/task-graph registration, and an empty tool
allowlist. An internal task-local isolation flag additionally disables tool
catalogue/provider discovery and rejects even attempted execution before logging
or shared-chat delivery. The production remote clients refuse to recreate a
missing isolated session with default grants. ChatGPT cache-key lookup/persistence
is bypassed for this request. Its output/events never reach the normal user
stream; the normal response is unchanged. Structured child tasks enforce an
8-second deadline, cancel/close the temporary session and join request cleanup;
no detached extraction survives its turn. A non-cooperative custom backend can
extend cleanup latency: bounded abandonment is deliberately not used. Close,
reset and backend replacement fence stale commits and close temporary sessions.
Backend replacement and same-session rebuild rotate the incarnation fence while
sharing the remaining logical-session budget and event deduplication. Old tokens
cannot reserve or commit, and subsequent turns can use only the remaining slots;
only logical reset/close or shutdown discards the budget.

The runtime checks the same tool-grant classifier before the extra request and
again for the proposed `memory.write`/`memory.update`; installed authorization
handlers also approve the concrete mutation. Read-only profiles cannot acquire
write capability through automation. Privacy rejects credential-shaped text,
sensitive paths, and overlong material before request assembly and again before
persistence; known key prefixes, credential fields, bearer/JWT/private keys and
credential-bearing URLs are covered. This is heuristic filtering, **not a
comprehensive secret detector**. At most 24 evidence items (2400 characters each),
24 relevant existing notes (8000 characters total), and a 32000-character / 64000-byte
assembled input are admitted. A saturated evidence ledger fails closed. Notes
are at most 1000 characters including preserved citation IDs and project paths;
raw transcript/logs and truncated evidence are not persisted.

`MemoryGraphStore.commitLearning` is a separate atomic transaction, not a call
to the legacy multi-draft `learn`. The model sees bounded lexically relevant
existing notes solely for semantic deduplication. A complete active-note content
set stays runtime-only for compare-and-swap and global exact/lexical-near-duplicate
checks. Any concurrent/manual content or archive change makes the proposal a
no-op. Semantic equivalence beyond the selected notes is **not guaranteed**.
Only IDs from the actual bounded lookup are accepted for updates. Automatic
updates enrich rather than erase manual information, preserve original metadata,
IDs, tags and archive boundaries, and skip a merge that exceeds the note budget.
This path does not generate embeddings; changed entries clear obsolete vectors.
An incarnation permit is rechecked inside the transaction: at most one mutation
per event and three per root session, including updates. Failed-save reservations
may conservatively consume budget. Retry races cannot spend the same event twice.
Successful commits use the existing memory-change notification; errors are
best-effort diagnostics, never a change to the work result.


ZenCODECore installs its own `ScoreThresholdMemorySelector` (a `MemorySelector`)
in place of the engine's default `TopScoreMemorySelector`. The default returns
every candidate up to `maxResults`, which would defeat the engine's
post-retrieval maintenance: every retrieved entry would be boosted and none
decayed (confidence flattens toward 1.0), and `selected.count >= 2` would nearly
always hold, so every recall would link its results pairwise at weight 0.7,
saturating the graph until cascade retrieval degenerates into noise. The
threshold selector keeps only candidates scoring at least half of the top hit,
restoring decay for weak candidates and limiting co-relevance linking to
genuinely strong matches. It makes no LLM call and no network request:
BM25/cascade scores have no absolute scale (they depend on corpus statistics),
so the cutoff is relative to each recall's best hit rather than a fixed
threshold. The engine's `MemoryVerifier` protocol is deprecated in favour of
`MemorySelector`. The five `memory.*` tool names
and the read-only vs mutating descriptor split are unchanged; `memory.write`
reports what actually happened — the tool emits `written`/`deduplicated` from
the store's `(entry, created)` outcome (`writeEntryOutcome`), so a write that
deduplicated against an active entry is reported as a duplicate returning the
existing entry, not as a save. `memory.update`
is an in-place content replacement that preserves the entry id (it does not
supersede), and no `global` memory scope is implemented or advertised — only
`project`. The public DTO surfaces only `.project`; the store maps it
internally to the engine's scope (`.all`) for `memory.search` and the
automatic recall pipeline, so the richer engine scopes never leak through the
facade.
