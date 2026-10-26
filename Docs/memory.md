# Memory Ownership and Persistence

This guide is part of the compatibility contract in
[architecture.md](architecture.md): the rules below are authoritative for
durable memory storage, retrieval, embedding, recall, and persisted formats.

Project memory is owned by the internal `ZenMemory` engine at
`Sources/ZenCODECore/Memory/Engine`; ZenCODECore's public `Memory`
domain is a thin async facade over it (`MemoryService` →
`MemoryGraphStore` → `ZenMemory` actor). The authoritative store is the
per-workspace graph file at
`<supportDirectory>/memory/<project key>/memory.graph.json`, where
`<project key>` is `<stem>-<first 24 hex of SHA256(name)>` for the project
name — the trimmed, NFC-normalized name of the workspace folder, compared
case-sensitively (`ProjectStorageKey`) — and `<supportDirectory>` honours
`ZENCODE_SUPPORT_DIRECTORY` (default `~/.zencode`). The graph therefore follows
a moved workspace folder, and two folders with the same name share one graph.
The graph is written atomically as sorted-key
pretty-printed JSON and is deliberately kept out of the workspace working tree
because it may embed float vectors. A process-wide `MemoryGraphStoreRegistry`
caches one open store per graph URL so parallel tool executions share a single
engine instance.

The global graph is a second persisted store, with the same format, version, and
registry as the workspace graphs, at
`<supportDirectory>/memory/global/memory.graph.json` (default
`~/.zencode/memory/global/memory.graph.json`, honouring
`ZENCODE_SUPPORT_DIRECTORY`). It is independent of the working directory and is
addressed as `MemoryGraphTarget.global`. A session whose selected profile has a
role with `AgentProfileRole.usesGlobalMemory` (today only `organizer`) uses it
for its `memory.*` tools and its automatic `<project-memory>` recall. Every other
role, and a session without a profile, uses the workspace graph of its working
directory (`MemoryGraphTarget.workspace(URL)`). Project graphs are never
aggregated into the global graph, and automatic learning (`consolidateMemory`)
never writes to it. A delegated sub-agent selects its graph from its own session
in the same way: the workspace graph of its working directory, or the global
graph when its profile has the `organizer` role.

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

The persistence layer keeps the last decoded graph together with the identity
of the file it was read from: device, inode, size, and modification time in
nanoseconds, read through `FileManager.attributesOfItem` (naming `struct stat`
is not portable under `MemberImportVisibility` on Linux). `load()`,
`reloadReadOnly()`, and the reload inside `transaction` (under `flock`) decode
again only when that identity has changed; a missing file clears the cache and
yields an empty graph. An unlocked read takes the identity again after the
bytes were read and keeps the pair only when the file did not change in
between, so a concurrent publish can never pair one file's identity with
another file's bytes — it simply costs one more decode. After a successful
publish the cache is re-primed with the staging file's identity (preserved by
`rename`) and the graph decoded from the bytes just written, so the next read,
typically the recall of the following turn, pays no decode. The cache does not
change semantics: a read returns exactly what decoding the current file would
return, and cross-process freshness holds because every ZenCODE writer publishes
via `rename`, which always creates a new inode.

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
strands the lock. The graph JSON carries `graph_version` (currently 3); a file
written by a newer engine is rejected on load and left byte-identical, while
older files decode through optional fields with contract defaults (`scope` →
`.project`, `active` → `true`, …). A file with no `graph_version` key at all is
the legacy v1 format (`MemoryGraph.legacyGraphVersion`): it is decoded with the
same contract defaults and normalized to the current version in memory. Loading
never rewrites the file — the on-disk graph stays byte-identical until an
explicit save (a mutation) writes the current version.

Graph version 3 stores each `embedding` as a base64 string of the little-endian
IEEE-754 binary32 components instead of a JSON number array, a lossless
encoding that preserves the bit pattern of every component. The decoder accepts
both forms, so v1 and v2 files load unchanged; the version is normalized to 3 in
memory, and the file is rewritten in v3 only by the first save (an explicit
mutation or a recall-maintenance checkpoint), never by loading. Earlier builds
reject a v3 file with `unsupportedGraphVersion(3)` and leave it byte-identical,
while malformed base64 or a payload that is not a multiple of four bytes fails
decoding as corrupt data. The format exists because 4096-dimensional vectors
made the pretty-printed JSON of a 239-entry graph about 21 MB, costing roughly
175 ms to decode and 280 ms to encode on every save; base64 reduces the file to
about 6 MB.

ZenCODECore exposes its own public DTOs (`MemoryEntry`, `MemoryScope`,
`MemoryCategory`) declared under `Models`; the internal `ZenMemory`
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
as seeds, then a breadth-first relation cascade with depth decay and a
per-retrieval confidence boost of the selected entries. Lexical tokens come
from `MemoryTokenizer`, applied identically to stored text and queries at
retrieval time (nothing derived from it is persisted): words are cut on
non-alphanumerics and on camel-case humps — `AgentCoreSessionRunner` yields
the whole lower-cased identifier and `agent`, `core`, `session`, `runner`, so
both an exact identifier and a prose query reach it — and every token goes
through a light English/Italian suffix stemmer (`tests`/`testing` → `test`,
`validated`/`validation`/`validazione`/`validata` → `valid`,
`memory`/`memories`/`memoria` → `memori`, `stabilize`/`stabilizzati` →
`stabiliz`), so the bilingual journal meets on shared roots where suffixes
allow it; digit-bearing tokens are never altered. It is a heuristic, not a
dictionary, and it does not translate: cross-language matches beyond shared
roots are the semantic path's job. Every score carries an
age discount (`MemoryAgePolicy`, `EngineMemoryEntry.effectiveConfidence`):
age is measured from the last content change (`max(createdAt, updatedAt)` —
a write, an update or an archive toggle; retrieval maintenance never touches
`updatedAt`), halves after 120 days for facts, entities and custom categories
(90 for preferences, 365 for corrections) and never falls below a floor of
0.2, so between two old entries relevance decides rather than a near-zero
factor; a logarithmic access boost lifts frequently selected entries and the
stored `confidence` scales the whole. The discount is applied to each ranking
*before* fusion — each stage over-fetches and re-sorts by
relevance × freshness, so a slightly older but better match keeps its rank,
whereas applying it after fusion would act on near-flat rank scores and sort
by age alone — and, after the cascade, only to the graph neighbours that
inherited a seed's decayed score, so every entry is weighted exactly once.
`memory.search` is strictly read-only: the
store's `search` runs the engine's `searchReadOnly` path, which shares the same
analyze → retrieve → select pipeline as recall but performs no transactional
maintenance — it never mutates `retrievalCount`/`confidence`/links and cannot
fail on a save error — while automatic recall (`context(for:)`) keeps its
maintenance-bearing path unchanged. The two differ in what they return: an
explicit search widens every retrieval stage (lexical, semantic and cascade
caps) to the requested `limit` (1–50, default 8) and returns the ranked
candidates — direct hits plus the graph neighbours the cascade reached — up
to that limit, whereas recall injects only the selector's thresholded subset
(see `ScoreThresholdMemorySelector` below), which guards what enters a turn
unasked. With `includeArchived`, archived entries are ranked with the same
BM25 over the archived subset (the active pipeline skips inactive nodes by
design) and up to half of the limit is reserved for them, so an explicitly
requested archived match stays reachable when active hits fill the page.
Automatic recall revalidates before it
commits: the maintenance transaction re-checks the retrieved candidates and
the selected set against the current graph draft, dropping any entry a
concurrent forget/archive/scope change made stale while the selector was
awaiting, and co-relevance linking only ever connects live endpoints (linking
a missing or inactive node is a no-op), so no dangling edges are persisted and
the returned result never contains eliminated entries. Without an embedder,
BM25 is the sole seed source. With an embedder, the semantic ranking is
**gated per prompt** and the rankings are merged by **max-normalised score
fusion** before the cascade; both rules were chosen by an A/B measurement of
the engine on a real 197-entry graph (14 Italian/English queries with
hand-judged relevance; harness: the opt-in `MemoryEmbeddingABLiveTests`).
Sentence embeddings are anisotropic: the cosine of a prompt against unrelated
entries is not 0 but a prompt-specific baseline (about 0.35–0.45 with
`qwen3-embedding-8b`) with a narrow spread, so the absolute floor
(`similarityThreshold`, 0.4) never filtered anything and every prompt —
including one with no relevant memory — produced a full semantic list.
`MemorySearch.semantic` therefore keeps a hit only when its cosine exceeds the
median of the prompt's distribution by `semanticMinimumZScore` (2.5) robust
standard deviations (1.4826 × median absolute deviation, which a few genuine
matches cannot inflate the way the standard deviation is; it falls back to the
standard deviation when more than half of the values coincide), still above
the absolute floor; a flat distribution yields no semantic seed. The gate
applies only with at least `MemorySearch.minimumGateSampleSize` (8) eligible
vectors, because with fewer a single outlier cannot reach the required z; small
graphs keep the absolute floor alone. Fusion then divides every ranking's
scores by that ranking's top score and sums the normalised values
(`MemorySearch.normalizedScoreFusion`, CombSUM): a hit that dominates one list
keeps a score no mid-ranked entry of two lists can reach, while an entry near
the top of both still outranks the top of either. Reciprocal-rank fusion
(`MemoryRankFusion.reciprocalRank`, k = 60) remains selectable as the measured
reference: its contributions are nearly flat, so any entry present in both
lists outranked an exact lexical hit whenever the semantic list was long and
noisy. Measured on that graph (automatic-recall configuration, ranked
candidates): BM25 alone MRR 0.74, recall@5 0.51, 3 queries with no relevant
entry in the top-5; the previous RRF + absolute-threshold pipeline 0.86 / 0.65 /
2 and one exact lexical top-1 displaced; the current defaults 1.00 / 0.74 / 0
with none displaced. Centering the vectors on the corpus centroid was also
measured and rejected (it lowered the pure-cosine rank of the relevant entries).

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
`https://openrouter.ai/api/v1/embeddings` and the referenced provider's ID;
without an OpenRouter provider no such proposal appears. Choosing it opens an
"OpenRouter embedding model" submenu listing the models of the public
OpenRouter catalog `GET https://openrouter.ai/api/v1/embeddings/models`
(requested without any API key, bounded by a 15-second timeout), each with its
name, price per million input tokens, and input-token limit. When the catalog
cannot be loaded or is empty, setup says so and shows a built-in snapshot of
that catalog instead. The submenu preselects the currently configured model
when the existing endpoint is OpenRouter and the model is listed, otherwise
`qwen/qwen3-embedding-8b`. This catalog request is the only network work setup
performs for embeddings. The manual add/change-endpoint path stays endpoint-only by
design: it never carries over the preset's model/provider reference, so an
edited endpoint cannot silently reuse the provider's key. For that manual
endpoint, setup validates the URL format entirely locally: it never
probes the endpoint, never enumerates models, and never asks for credentials.
When an endpoint is configured, setup shows a note stating that the full text of
every prompt (operator and sub-agent turns, for automatic recall) and of every
memory entry written or updated is sent to that endpoint; without an endpoint,
retrieval stays local (BM25).
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
resolves the session's graph (the workspace graph, or the global graph for
`organizer` sessions) and runs the store's `context(for:scope:)`
inline: offline BM25 seeds, graph expansion, and selection through
`ScoreThresholdMemorySelector`. Without an endpoint, retrieval is local BM25
and costs no extra round trip; with an endpoint, a bounded HTTP call to the
embedding service adds semantic similarity and fusion. Neither adds a second
LLM call — what reaches the wire is the formatted block, which
does add input tokens to the outgoing request and is therefore bounded by a
character budget (`ZENCODE_MEMORY_RECALL_MAX_CHARACTERS`, default 4 000
characters, clamped to [200, 32 000]; ZenCODE counts roughly four characters
per token, so the default is about 1k tokens of recalled memory). The local part
of the pipeline, including the one-time JSON graph open on a cold workspace,
is bounded by `ZENCODE_MEMORY_RECALL_TIMEOUT_MS` (default 150 ms, clamped to
[10, 5000]). When an embedding endpoint is configured, the total budget of the
recall, including the HTTP request to the embedding service, is governed by
`ZENCODE_MEMORY_RECALL_SEMANTIC_TIMEOUT_MS` (default 6 000 ms, clamped to
[10, 10 000]) instead. Resolution: an explicit
semantic value wins; otherwise, if `ZENCODE_MEMORY_RECALL_TIMEOUT_MS` is set and
parseable, it also governs the semantic path, so one variable limits every
recall; otherwise the 6 000 ms default applies. Unparseable values count as
unset. At steady state the graph read is served from the reload cache, so an
unchanged file is not decoded again. When an embedding provider is configured,
`MemoryTurnCoordinator` prepares a maintenance-free local BM25 result alongside
the full semantic recall. The deadline task sleeps for the local bound; if the
store is already resolved and has an embedder at that point, it keeps waiting
up to the semantic bound before the prepared lexical block is injected. A
semantic result completed within that bound wins, and the losing request is
cancelled without being awaited. A store still opening at the local bound (cold
open) cannot extend the wait: the first turn on a cold workspace keeps the local
bound and may be served by the lexical fallback. Without an embedder nothing
changes. The extension exists because hosted endpoints such as OpenRouter answer
in a few hundred milliseconds, and a single 150 ms bound cancelled the semantic
request on nearly every turn, leaving recall silently lexical despite a
configured endpoint; the semantic default was then raised from 1 500 ms to
6 000 ms because, measured against OpenRouter on a real graph, the embedding
request takes 0.5–2 s at the median with tails of several seconds, so the
shorter bound still dropped a third to a half of the recalls onto the lexical
fallback. If the graph cannot
open or the local fallback itself is not ready at the deadline, recall resolves
to no block, which makes the outgoing request byte-identical to one sent with
memory switched off. A session is auto-disabled after three consecutive
unusable attempts; a delivered lexical fallback counts as a success, any other
success resets the counter, and closing or resetting a session discards its
state. Both degradations are visible rather than silent: a pause emits one
warning line per pause event, and a lexical fallback injected because the
semantic request missed its bound emits one warning line per session (every
occurrence is also logged at debug level), on the same channels as the
embedding-failure diagnostics — an installed TUI sink or the preserved stderr
descriptor, plus the opt-in `ZenLogger` copy — so a broken graph or a
chronically slow endpoint cannot quietly turn recall off or lexical. The
request itself stays byte-identical. The memory-tool prompt tells the model
that a missing `<project-memory>` block means either nothing relevant was
found or recall was unavailable, and to call `memory.search` before concluding
that no prior context exists.

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
once. The same helper also merges a turn instruction, when a turn binds one,
after the block and under the same rules (see [voice.md](voice.md)).
`session.messages` is never mutated, so the block never enters
conversation history, saved-session snapshots, or the session cache key;
saved-session and prompt-cache compatibility are preserved. The alternatives
were rejected on purpose: `systemPrompt` participates in the session cache
key, and `dynamicContext` is compared by
`matchesSessionIdentityIgnoringThinking`, so either would rotate the cache key
or force a `createSession` on every turn.

The block is an explicitly labelled container (`<project-memory>` …
`</project-memory>`) so the model reads it as background context, not as text
the user just typed. Inside it, `BulletMemoryContextFormatter` renders every
selected entry as one bullet whose first line carries the entry id
(`- [id: <UUID>] …`) — the same id `memory.update` and `memory.archive`
accept, so the model can act on what it was shown without a lookup first —
with the entry's remaining lines indented beneath it. Two properties are
enforced when the block is built: recalled content is escaped so no
`project-memory` tag inside an entry can close the container (both the
`<project-memory` and `</project-memory` spellings are rewritten to
`&lt;project-memory` / `&lt;/project-memory`, case-insensitively, leaving code
otherwise untouched), and the payload is truncated to the recall character
budget on entry boundaries, in ranking order: a bullet and its continuation
lines are one unit, so a journal entry is never cut between its `Summary`,
`State` and `Next`, and a notice reports how many entries were omitted. When
not even the first entry fits, it is clipped rather than dropped and the
notice says so. The fixed header, the tags and the notice are constant
overhead on top of the budgeted payload.

The main model owns durable memory explicitly through the seven `memory.*`
tools — read-only `memory.read`, `memory.search`, `memory.get`; mutating
`memory.write`, `memory.update`, `memory.archive`, `memory.restore` — guided by
`MemoryService.toolUsagePromptSection()` (search before writing, update
instead of duplicating, archive stale entries, prefer fresh evidence over
memory). `memory.read` pages the journal newest-first (`offset`, `limit`,
`hasMore`) and both reads and searches accept a `MemoryEntryFilter` (`tags`,
all required and case-insensitive; `category`). `memory.get` returns one entry
by id, archived or not; `memory.restore` reactivates an archived entry.
`memory.write` never blocks on similarity: after creating an entry it reports
up to three active entries whose words cover much of the new content —
scored with the engine's BM25 using the new content as the query, relative to
the entry's own score, reported at 0.5 or above — so the model can consolidate
with `memory.update` and archive the other note; exact duplicates are still
deduplicated. For every tag that only the new entry carries, the result also
lists existing tags sharing a word with it (`tagHints`, most used first, e.g.
`linux-validation` → `linux`, `validation`), so the tag vocabulary converges
instead of growing one single-use tag per note. `memory.update` preserves `Timestamp` and always stamps
`Updated` with the time of the update, replacing a stale `Updated` line the
caller carried over. An entry's title is its `Summary`, or else its first line
that is not a `Timestamp`/`Updated` annotation. `MemoryTurnCoordinator`
drives recall only, and
`MemoryTurnCoordinator.discard(sessionID:)` drops only per-session recall health
state on close/reset/rebuild. The engine's `learn(from:)`, its default
`NoopMemoryExtractor` (which extracts nothing), and its LLM-backed extractor
stay unwired internals of `ZenMemory`. Selective product consolidation instead
uses the runner-owned same-backend path described below; opening a store alone
still never performs an extraction request.

## Memory cleanup

Bulk cleanup of a graph runs only from `/setup` › Data management ›
**Clean memory**: there is no slash command, command-line flag, `memory.*` tool
or automatic run, and nothing is saved in `settings.json` or read from the
environment (the thresholds are asked for each time). The flow lists the graphs
found under `<supportDirectory>/memory/` (the current project, the global graph,
and the other projects), applies the chosen rules to one of them, and shows a
preview with counts and titles before asking for an explicit confirmation
(default No). The rules, which can be combined, measure age from the last
change, `max(createdAt, updatedAt)`, like retrieval does:

- **Remove archived entries** physically deletes archived entries
  (`active == false`) unchanged for at least N days (default 30; 0 removes
  every archived entry).
- **Archive stale entries** archives active entries that were never recalled
  (`accessCount == 0`) and have not changed for at least N days (default 180,
  at least 1). The threshold is scaled per category with the half-lives of
  `MemoryAgePolicy.default`, `N × halfLife(category) / 120`: a preference
  after 0.75 N, a correction after about 3.04 N, the other categories after N.
  Archiving stamps `updatedAt`, so **Remove archived entries** can only delete
  such an entry N days later; an entry archived in a run is never removed in the
  same run.
- **Graph hygiene** removes inactive entries that were superseded
  (`supersededBy`), edges whose source or target no longer exists, tags and
  clusters without members (recounting the others), and embedding vectors the
  store cannot use: every vector when no embedding provider is configured,
  otherwise those whose `embedding_model` differs from the provider the store
  was opened with. A vector is not recomputed by the cleanup; it is regenerated
  only by the next `memory.update` or `memory.write` of that entry (there is no
  batch re-embedding).

Applying a cleanup is one engine transaction under the graph's file lock. The
plan is computed again on the graph reloaded under the lock, so it can differ
from the preview if another process wrote in between, and the report shown
afterwards is the one applied. Before the graph changes, the pre-cleanup graph
is written in the persisted format to `memory.graph.json.bak` in the same
directory, through the owner-only staging file and `rename` used by saves: a
previous copy is replaced atomically, only the last pre-cleanup state is kept,
and a failing backup aborts the transaction with nothing saved. A plan that
changes nothing writes neither the graph nor the backup. The engine never loads
the `.bak` file; restoring it is manual, with `zen` closed (copy it over
`memory.graph.json`). It lives in the support directory, so a Data management
export includes it. `graph_version`, the on-disk formats, the `memory.*` tools
and the public `MemoryService` API are unchanged.

For the graph of another project (never the current project and never the
global graph), the same menu can instead delete the whole
`<supportDirectory>/memory/<project key>/` directory. The confirmation names the
exact path, no copy is made, and the cached store for that graph is dropped so
a stale engine cannot write it back.

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
post-retrieval maintenance: every retrieved entry would be boosted (confidence
flattens toward 1.0), and `selected.count >= 2` would nearly always hold, so
every recall would link its results pairwise at weight 0.7, saturating the
graph until cascade retrieval degenerates into noise. The threshold selector
keeps only candidates scoring at least half of the top hit, limiting the boost
and co-relevance linking to genuinely strong matches. Rejected candidates are
left untouched: `decayRejectedBy` defaults to 0, so being retrieved near a
prompt without being chosen costs an entry nothing, and the boost records the
access without touching `updatedAt`. It makes no LLM call and no network
request: BM25/cascade scores have no absolute scale (they depend on corpus
statistics), so the cutoff is relative to each recall's best hit rather than a
fixed threshold. The engine's `MemoryVerifier` protocol is deprecated in favour
of `MemorySelector`. The original five `memory.*` tool names are unchanged
and the read-only vs mutating descriptor split is preserved — `memory.get`
joined the read-only set and `memory.restore` the mutating one, so read-only
profiles gain the lookup but never the reactivation; `memory.write`
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
