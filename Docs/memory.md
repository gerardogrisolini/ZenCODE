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
The graph is two files in that directory: `memory.graph.json`, written
atomically as sorted-key pretty-printed JSON, and, from graph version 4,
`memory.graph.json.vectors`, a binary file with the entries' embedding vectors
(see the vectors file below). Both are owner-only (0600 in a
0700 directory), sit next to the stable `memory.graph.json.lock` used for
`flock`, and are deliberately kept out of the workspace working tree because
the vectors are derived from the entries' content. A process-wide `MemoryGraphStoreRegistry`
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

Opening loads only the graph files — the JSON and, for a version 4 graph, its
vectors file — or starts with an empty graph if no JSON file exists. `open`
never persists: a cold `memory.search` / `memory.read`
neither creates the graph files nor requires a writable support directory.
The first mutation atomically persists the graph. An existing `MEMORY.md`,
whether valid, malformed or unreadable, is completely ignored: it is not
read, parsed, imported, embedded, rewritten or deleted. Its contents cannot
influence memory reads, searches or automatic recall. Previously persisted
JSON graph entries remain available; JSON version compatibility is unchanged.
The file-specific template, filename constant and document errors are removed;
the deprecated synchronous APIs that operate on the graph remain supported.

The persistence layer keeps the last decoded graph together with the identity
of the files it was read from — the JSON and, when it exists, the vectors
file: device, inode, size, and modification time in
nanoseconds, read through `FileManager.attributesOfItem` (naming `struct stat`
is not portable under `MemberImportVisibility` on Linux). `load()`,
`reloadReadOnly()`, and the reload inside `transaction` (under `flock`) decode
again only when either identity has changed; a missing JSON clears the cache and
yields an empty graph. An unlocked read takes both identities again after the
bytes were read and keeps the result only when neither file changed in between,
so a concurrent publish can never pair one save's identities with another
save's bytes; otherwise it reads again, up to three times, and then returns its
last decode uncached, which the fingerprints keep safe (a mixed pair can only
lack vectors, see the vectors file below). After a successful
publish the cache is re-primed with the identities of the staging files
(preserved by `rename`) and the graph decoded from the bytes just written, so
the next read, typically the recall of the following turn, pays no decode. The
persistence also keeps the exact bytes of the vectors file it last read or
wrote, with that file's identity: a save rewrites the vectors file only when the
bytes it would write differ or the file on disk is no longer the one recorded,
so a save that changes no vector — an access count, a link, the text of an entry
without a vector — republishes the JSON alone. The cache does not change
semantics: a read returns exactly what decoding the current files would
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
strands the lock. The graph JSON carries `graph_version` (currently 4); a file
written by a newer engine is rejected on load and left byte-identical, while
older files decode through optional fields with contract defaults (`scope` →
`.project`, `active` → `true`, …). A file with no `graph_version` key at all is
the legacy v1 format (`MemoryGraph.legacyGraphVersion`): it is decoded with the
same contract defaults and normalized to the current version in memory. Loading
never rewrites the files — the on-disk graph stays byte-identical until an
explicit save (a mutation) writes the current version.

Graph version 3 stored each `embedding` as a base64 string of the little-endian
IEEE-754 binary32 components instead of a JSON number array, a lossless
encoding that preserves the bit pattern of every component. The decoder still
accepts both forms, so v1, v2 and v3 files load unchanged; they are normalized to
the current version in memory and rewritten only by the first save (an explicit
mutation or a recall-maintenance checkpoint), never by loading. Builds before
version 3 reject a v3 file with `unsupportedGraphVersion(3)` and leave it
byte-identical, while malformed base64 or a payload that is not a multiple of
four bytes fails decoding as corrupt data. That format existed because
4096-dimensional vectors made the pretty-printed JSON of a 239-entry graph about
21 MB, costing roughly 175 ms to decode and 280 ms to encode on every save;
base64 reduced the file to about 6 MB.

**The vectors file.** Graph version 4 takes the vectors out of the JSON.
Entries keep `embedding_model` but no longer have an `embedding` key: their
vectors are in `memory.graph.json.vectors` (`MemoryVectorFile`), one binary
file next to the JSON, rewritten as a whole through an owner-only staging file
and `rename` like the JSON, and only when the bytes it would hold change. Why:
with base64 vectors the JSON of the ZenCODE graph (289 entries, 280 vectors of
4096 dimensions) had grown to 8.7 MB, and the whole file was rewritten by every
mutation and by every recall-maintenance checkpoint (every 4 recalls by
default), that is many times a day for vectors that almost never change. Saved
as version 4, the same graph is a 2.5 MB JSON plus a 2.3 MB vectors file, and
only a change of a vector rewrites the latter. The components are IEEE-754
binary16, which halves the vectors again; the choice was measured: on that
graph re-embedded with `qwen/qwen3-embedding-4b` (240 active entries, 2560
dimensions) the A/B harness (`ZENCODE_AB_COMPARE_FLOAT16=1`, same vectors and
same query embeddings in one run) gave identical aggregates for binary32 and
binary16 vectors, with no top-5 change in any of its 140 per-query rows and a
largest component error of 3.1e-5. The component type is in the header, so a
binary32 file stays readable. The harness copies the graph named by
`ZENCODE_AB_GRAPH_PATH` together with its `memory.graph.json.vectors`, so a
version 4 graph is measured with its vectors.

Every integer is little-endian on every platform, and the bytes are a function
of the graph alone (records sorted by the UTF-8 bytes of the id):

```
header   magic "ZMVF" (4 bytes) · format version UInt16 = 1
         component type UInt16 (1 = binary16, 2 = binary32) · record count UInt32
record   id length UInt16 · id (UTF-8) · fingerprint UInt64
         content length UInt32 (UTF-8 bytes) · dimension UInt32
         components (dimension × 2 or × 4 bytes)
```

Every entry with a vector has a record, archived ones included; a graph without
vectors has a file with no records. The fingerprint is the 64-bit FNV-1a hash of
the UTF-8 bytes of the entry's `embedding_model` (`unspecified` when absent),
one 0x00 byte and the UTF-8 bytes of its `content`. On load a record's vector is
given to an entry only when the JSON just decoded has an entry with that id, the
same content length and the same fingerprint; any other record is ignored. The
fingerprint detects accidental mismatches, not tampering: the files are
owner-only, and it is not a cryptographic hash (the graph, BM25 path and
persistence stay dependency-free). A save writes the vectors file first and the
JSON second, both under the graph's `flock`. Whatever pair of files a reader
meets — a crash between the two writes, an unlocked read during a publish, a
backup copied without its vectors file — an entry can at most come back without
a vector (for an entry whose text or model changed in between), never with the
vector of another text or model; **Data management › Rebuild memory
embeddings** gives those entries a vector again. An inline `embedding` in a
version 4 JSON is ignored.

A missing, unreadable, truncated or corrupt vectors file, or one with an unknown
format version or component type, is not an error: the file is checked as a
whole (every length against the bytes left, no trailing bytes, no duplicate id,
valid UTF-8) and, if it fails, the graph loads without vectors, so recall uses
BM25 for every entry until the next save rewrites the file and a re-embedding
fills it. Loading still writes nothing. A corrupt JSON remains an error, as
before.

In memory every vector is held at the stored precision: assigning one — from
the embedding provider, from an inline v1–v3 vector or from the vectors file —
rounds each component to the nearest binary16 value (ties to even, subnormals
and signed zeros kept, beyond ±65504 to an infinity; embedding components are
far smaller). The conversion is written by hand (`HalfPrecision`), because
Swift's `Float16` does not exist on macOS x86_64 and the bytes must be the same
on every platform. Therefore the graph an engine adopts after a save, and the one
the cache is re-primed with, are exactly what decoding the files just published
returns; a v3 graph loads with the values its first save writes; and writing
back the binary32 vector a provider returned is not a change, so it never
republishes anything. Earlier builds reject a version 4 graph with
`unsupportedGraphVersion(4)` and leave both files untouched; there is no
export back to version 3. A version 3 JSON next to a vectors file (for instance
an old copy put back by hand) uses its inline vectors and ignores the file.

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
`qwen/qwen3-embedding-4b`; a model already saved, such as the earlier default
`qwen/qwen3-embedding-8b`, stays valid. This catalog request is the only network work setup
performs for embeddings. The manual add/change-endpoint path stays endpoint-only by
design: it never carries over the preset's model/provider reference, so an
edited endpoint cannot silently reuse the provider's key. For that manual
endpoint, setup validates the URL format entirely locally: it never
probes the endpoint, never enumerates models, and never asks for credentials.
When an endpoint is configured, setup shows a note stating that the full text of
every prompt (operator and sub-agent turns, for automatic recall) and of every
memory entry written or updated is sent to that endpoint; without an endpoint,
retrieval stays local (BM25).
When "save and exit" stores an embedding configuration that differs from the
one setup started with and resolves to a provider, setup then offers to
re-embed every memory graph; see [Memory re-embedding](#memory-re-embedding).
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
by id, archived or not; `memory.restore` reactivates an archived entry and,
with an embedding provider, gives it a vector when it has none from that model
(see [Memory re-embedding](#memory-re-embedding)).
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
  by the next `memory.update`, `memory.write` or `memory.restore` of that
  entry, or for every graph at once by Data management › **Rebuild memory
  embeddings** (see [Memory re-embedding](#memory-re-embedding)). It also
  trims the co-relevance links of graphs written
  before the per-entry cap existed: every entry is reduced to at most 12
  outgoing `relatesTo` edges with the same criterion recall applies when it
  makes room (weakest first, the oldest among equals — on a graph whose links
  all weigh 0.7, the 12 most recent survive), and each removal takes the mirror
  link with it. It runs after the dangling edges are gone, visits entries in id
  order, so the result is deterministic, and a second run over the result
  changes nothing. Only `relatesTo` edges are touched: tag, cluster, supersedes,
  contradicts and derived-from edges stay. The report counts every removed edge,
  both directions, as "excess links". No format change: hygiene adds no field
  to the graph.

Applying a cleanup is one engine transaction under the graph's file lock. The
plan is computed again on the graph reloaded under the lock, so it can differ
from the preview if another process wrote in between, and the report shown
afterwards is the one applied. Before the graph changes, the pre-cleanup graph
is written in the persisted format to `memory.graph.json.bak` and its vectors
to `memory.graph.json.vectors.bak` in the same directory (the vectors first),
through the owner-only staging files and `rename` used by saves: a previous
copy is replaced atomically, only the last pre-cleanup state is kept, and a
failing backup aborts the transaction with nothing saved. A plan that changes
nothing writes neither the graph nor the backup. The engine never loads the
`.bak` files; restoring them is manual, with `zen` closed: copy
`memory.graph.json.bak` over `memory.graph.json` and
`memory.graph.json.vectors.bak` over `memory.graph.json.vectors`. Copying only
the JSON is safe as well: thanks to the fingerprints, an entry whose text or
model differs from what the live vectors file was written for just comes back
without a vector, which **Rebuild memory embeddings** restores. The backup lives
in the support directory, so a Data management export includes it. The graph
list of **Clean memory** shows the size of the JSON and the vectors file
together. The on-disk formats, the `memory.*` tools and the public
`MemoryService` API are not changed by the cleanup.

For the graph of another project (never the current project and never the
global graph), the same menu can instead delete the whole
`<supportDirectory>/memory/<project key>/` directory. The confirmation names the
exact path, no copy is made, and the cached store for that graph is dropped so
a stale engine cannot write it back.

## Memory re-embedding

Vectors from another model are never compared (see above), so after the
embedding model changes every entry embedded with the previous one falls back
to keyword matching until it is embedded again. Re-embedding does that for
every graph under `<supportDirectory>/memory/` (the current project, the global
graph and the other projects), with the provider each store opens with from
the saved settings. It runs from two places only; there is no slash command,
flag, `memory.*` tool or automatic run:

- **After setup.** Right after "save and exit" has written `settings.json` and
  reset the store registry, so the stores reopen with the new provider, setup
  offers it when `memoryEmbedding` differs from the configuration setup started
  with and the new one resolves to a provider. Switching to BM25 offers
  nothing, and a cancelled setup never touches a graph.
- **Data management › Rebuild memory embeddings.** The same flow on demand,
  with the provider of the settings saved on disk (not changes staged in the
  current setup run), for instance to resume a stopped run or to retry failed
  entries. Without a configured endpoint it says so and does nothing.

Before anything is sent, a list shows the model and, for each graph by folder
name, the active entries to embed — those without a vector or with a vector
from another model — and the archived entries whose vector is deleted, then
the total. Building it makes no request. A graph with nothing to do is listed
as "up to date"; when no graph has anything to do, nothing is asked (after
setup, nothing is printed either). The list recalls that the content of each
entry is sent to the embedding endpoint, and the confirmation defaults to Yes.
Declining after setup points to Data management › Rebuild memory embeddings.

The run, graph by graph:

- **Archived entries** are not embedded, since they are never recalled: their
  vectors are deleted first, without touching `updatedAt`. Archiving an entry
  still keeps its vector.
- **Text and order.** Each request embeds the stored `content`, exactly the
  text `memory.write` and `memory.update` embed, so the vector is the one a
  fresh write would produce. The newest entries go first.
- **Vector length.** The first successful answer of the run fixes the
  dimension. An active entry whose vector comes from the right model but has
  another length, which recall skips, is embedded again too: the list cannot
  see lengths, the summary counts these entries.
- **Blocks.** At most 4 requests are in flight. Vectors are requested outside
  any transaction and saved every 16 entries in one engine transaction, which
  sets a vector only if the entry still exists, is still active, still has the
  content that was embedded and has not meanwhile received a compatible vector:
  a concurrent write, update, archive or delete, from this or another process,
  always wins. A stop or a crash therefore leaves every entry either with its
  new vector or as it was, without a vector or with one recall ignores.
- **Retries.** HTTP 429 (OpenRouter answers "Model busy" under load), 408, 5xx
  and transport failures are retried, up to 5 attempts per entry, after 1, 2, 4
  and 8 seconds. An entry that exhausts its attempts, or fails in any other
  way, keeps its previous state and is counted as failed; the run goes on.
- **Aborts.** HTTP 401, 403 or 404 stops the whole run at once, and so does a
  run whose first 8 entries all fail: no further request is sent. Messages
  carry only a status or an error kind, never a key, a token, the endpoint URL,
  a response body or entry text.

While a graph runs, one line is rewritten in place, for example
`ZenCODE-…: 120/238 (2 failed) · Esc to stop`. **Esc** stops cleanly: no new
request is sent, not even a pending retry, the requests in flight finish and
their vectors are saved, then the run stops and the summary says how to
resume. Ctrl-C keeps its meaning and ends the process; the blocks already
saved stay. The Esc watch is the one used while a turn generates
(`TerminalEscapeStopMonitor`); it is torn down at the end of every run, so the
terminal leaves raw mode before the summary. The summary lists, per graph and
in total, the entries embedded, failed, skipped because they changed meanwhile
and not reached, the archived vectors deleted, and the model with the observed
dimension.

`memory.restore` closes the remaining gap: when the store has an embedding
provider and the restored entry has no vector from its model, the vector is
computed after the restore transaction and saved in a second one, only if the
entry is still active and its content is unchanged. An endpoint failure is
reported like any other mutation fallback and leaves the entry on BM25; the
restore itself never fails because of it.

Re-embedding adds no field to the file format. The dimension of a vector is its
length (the `dimension` of its record in the vectors file).

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
every recall would link its results pairwise, saturating the
graph until cascade retrieval degenerates into noise. The threshold selector
keeps only candidates scoring at least half of the top hit, limiting the boost
and co-relevance linking to genuinely strong matches. Even then the links are
bounded (`MemoryRelationPolicy`, carried by `MemoryEngineConfiguration`, so a
replayed maintenance batch applies the policy it was recorded with): a pair
selected together is linked in both directions at weight 0.7, and every further
co-selection of the same pair adds 0.05 up to 0.9 — an existing weight is
never lowered, so a legacy 1.0 stays 1.0, and a pair known in only one
direction takes the heavier weight in both. Each entry keeps at most 12
outgoing `relatesTo` links: before a new link is added to an entry that is at
or over the cap, that entry's weakest links go — the oldest among equals, even
when the weakest weighs as much as the newcomer — until it is back below 12,
and every removed link takes its mirror with it. Reinforcing an existing link
never evicts anything, so recall tidies the entries it touches while the
cleanup's **Graph hygiene** trims the whole graph. The new weight is stored in
place, so the position of a link — its age for eviction — is that of its
creation; only `relatesTo` edges are ever added or removed this way, and the
reverse index drops a source only when no edge of another kind still joins the
two entries. The links add no field to the file format: the weight is the
`weight` the `relates_to` edge already carried.
Rejected candidates are
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
