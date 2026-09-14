# Authenticated subscription model catalogs

Subscription discovery runs only during setup/reconfiguration. It does not poll
in the background, switch the active runtime model, rewrite saved IDs, or use
public/third-party catalogs or bundled lists to find new models. The API-key
`RemoteModelCatalogClient` remains separate.

## Requests and evidence

- ChatGPT: `GET https://chatgpt.com/backend-api/codex/models?client_version=X.Y.Z`,
  Bearer authentication and `ChatGPT-Account-ID`. The version is ZenCODE's version,
  normalized to three numeric components without prerelease/build suffixes.
  The official Codex contract was inspected at commit
  `99b3ab2131a8672089fd7d78da62483187ba1122`; a prior read-only diagnostic returned
  HTTP 200 and eight models. This is not a promise of a stable third-party API.
- Anthropic: `GET https://api.anthropic.com/v1/models`, Bearer authentication as
  supported by the official SDK `auth_token`, `anthropic-version: 2023-06-01`,
  and the existing generation OAuth beta `oauth-2025-04-20`. No new beta was
  invented. Pagination uses `has_more`/`last_id` and `after_id`; repeated cursors
  and excessive pagination fail instead of caching partial results. Every page must
  contain a JSON boolean `has_more`; missing, string, null or numeric markers are
  invalid. A true marker also requires a nonblank, nonrepeated string `last_id`.
- Requests have a 10-second per-page timeout, ephemeral HTTP sessions, and do not
  follow redirects. Response bodies and credentials are never included in errors.
  Discovery itself does not refresh tokens or initiate login; setup retains its
  existing credential-acquisition flow.

**Anthropic limit:** server acceptance of subscription OAuth on the Models
endpoint has **not** been validated live. The prior diagnostic found expired
credentials and made no Anthropic request. This implementation was approved with
fixture-based coverage of Anthropic; no live Anthropic login, refresh, or request
was performed. SDK Bearer support does not itself establish server entitlement,
nor does it resolve provider restrictions on third-party OAuth use. A 401/403 is
reported explicitly and is never presented as successful access via cached data.

Official references:

- [Codex models endpoint](https://github.com/openai/codex/blob/99b3ab2131a8672089fd7d78da62483187ba1122/codex-rs/codex-api/src/endpoint/models.rs)
- [Codex model metadata](https://github.com/openai/codex/blob/99b3ab2131a8672089fd7d78da62483187ba1122/codex-rs/protocol/src/openai_models.rs)
- [Anthropic List Models and capability schema](https://platform.claude.com/docs/en/api/models/list)
- [Anthropic SDK](https://github.com/anthropics/anthropic-sdk-python)
- [Anthropic authentication/credential restrictions](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)

## Metadata and generation

ChatGPT reads `models`, `slug`, `display_name`, `visibility`, `context_window`,
`max_context_window`, `supported_reasoning_levels[].effort`,
`default_reasoning_level` and `input_modalities`.
All `visibility=list` entries returned by the provider are offered.
`minimal_client_version` is not filtered locally: it refers to Codex requirements,
whereas the transmitted version identifies ZenCODE and is not comparable to a Codex
release. Neither that identity nor catalog visibility establishes runtime compatibility.
No supported Codex version is invented or advertised.
` supported_in_api` is deliberately **not** a subscription filter. The current
`context_window` and representable reasoning levels/default enter the manifest;
maximum context and input modalities are retained as catalog metadata, not a
promise to implement additional multimodal transports or automatically enlarge
context windows.

Discovered ChatGPT effort values are persisted in optional
`subscriptionReasoningLevels` generation metadata. Wire `none`/`off` explicitly map
to internal `off`; `minimal` remains `minimal` through manifest serialization and
request generation. The advertised wire value is sent unchanged (when both off
aliases are present, the first advertised alias is used), including explicit
no-thinking effort without a reasoning summary. An off-only catalog entry exposes
only `[off]`, not enabled thinking. Legacy manifests without this metadata retain
the previous off omission and minimal-to-low behavior.

Anthropic reads `data`, IDs/titles, `max_input_tokens`, `max_tokens`, and explicit
`capabilities.thinking.types.adaptive/enabled`, `capabilities.effort` levels,
`image_input` and `pdf_input`. A fully declared adaptive mode with supported
levels is persisted as `subscriptionThinkingMode=adaptive` in generation overrides;
manual `enabled` mode exposes the on/off budget path. Generation uses the persisted
mode and levels, not ID-based guesses. Adaptive discovery does not infer support
for `thinking.display=summarized`; no such field is sent without a capability
contract. Input modality flags remain informational.

Missing/unknown capabilities persist an explicit disabled mode and `[off]`.
Static subscription catalogs and all model-ID-based defaults, limits and capability
fallbacks have been removed. Context limits come only from configured metadata;
without a limit the context window is unknown. Anthropic output uses the configured
catalog/runtime budget (the smaller positive limit when both exist), or a generic
4096-token fallback. Thinking mode and authorized levels must be explicit; legacy
manifests without a mode no longer infer adaptive/manual thinking from their IDs.
Long-context and thinking beta headers likewise follow configured limits and modes.
The linked Anthropic API-key thinking path also consumes configured authorization,
not subscription model-ID heuristics. Its existing generic 64000-token output
default is preserved. Without an explicit mode, authorized API-key thinking uses
a generic manual budget; adaptive is no longer inferred from legacy IDs.

Existing configured models are reused verbatim, including custom IDs, limits,
options and defaults; models missing from discovery remain available as configured
entries. Persisted `chatgpt`/`claude` prefixes and `:`/`/` syntax remain readable,
but a provider-only ID is not an actual model: generation requires a configured
model and reports the existing missing-provider configuration error otherwise.
Older manifests still decode, but use their metadata and generic fallbacks rather
than their former bundled-model behavior. Reconfigure to populate missing metadata.
Users may still explicitly deselect models in setup.

## Last-success cache and identity

Files are stored directly in the support directory (`~/.zencode` by default,
respecting `ZENCODE_SUPPORT_DIRECTORY`):

`subscription-catalog-<provider>-<opaque-scope>.json`

Schema 1 contains provider, scope, client version, success timestamp and normalized
model metadata. It contains **no access/refresh tokens, token hashes, raw account
IDs, request headers, or raw server response/error bodies**. Files are written
atomically with mode 0600; their support directory is hardened to 0700. Existing
symlinks/unexpected node types are rejected using the sensitive-file boundary.
A cache write failure warns but does not discard a successfully fetched catalog.

ChatGPT scope is a one-way digest of the account ID (never of a credential).
Anthropic scope is a random UUID `catalogScopeID` created by a successful new OAuth
authorization-code exchange and preserved on refresh. A later login receives a
new UUID; it cannot reuse a previous login's cache. The additive optional field
keeps old credentials decodable. Legacy/environment Anthropic credentials without
this field do **not** reuse persistent catalogs; a future new sign-in is needed
for durable caching. No automatic login/refresh is performed to establish scope.
Unidentified ChatGPT credentials likewise do not use persistent cache.

Every setup call holds one immutable credentials/scope snapshot. Results only
return to that caller, never to a global mutable account catalog or runtime model
registry. Cooperative cancellation is checked after network work and before
persistence; cancellation and 401/403 never fall back to cache. Account/login
changes use different files, and orphaned old cache files grant no access. Cache
files may be deleted manually; they are not credentials.

A refresh is attempted on each setup invocation. On transient HTTP/network or
parsing failure, the last successful matching provider/scope/schema/client-version
snapshot is offered with its timestamp and a stale/access warning. There is no
expiry-based deletion of the last success. An empty successful catalog replaces
an older catalog; it is not treated as an error or grounds for resurrecting removed
models. Without a valid cache, failure is explicit and setup does not overwrite
configured models. A partial paginated result never replaces the prior snapshot.

## Fixture validation

`SubscriptionModelCatalogTests` covers requests, metadata, visibility filtering
without comparing ZenCODE identity to Codex version requirements, cached success/failure, account isolation, rotated tokens, authentication
rejection, cancellation, empty catalogs, permissions/symlinks and saved candidates.
`SubscriptionCatalogAnthropicMetadataTests` covers capability-driven new IDs,
conservative unknown thinking, OAuth lineage persistence/legacy decode, simulated
refresh, and Anthropic cache isolation. No live test is required for these suites.
Build/test execution and independent review are separate gates; fixture success
must not be reported as proof of live Anthropic subscription compatibility.
`SubscriptionCatalogReasoningRoundTripTests` adds catalog-to-persisted/copied-manifest
and payload coverage for none/off/minimal and legacy metadata.
`SubscriptionCatalogPaginationValidationTests` adds malformed/missing completion
markers on both first and second pages, asserting the prior cache is byte-identical.
These review-correction tests require independent validation; no new build/test or
live/login/refresh execution was performed by the implementing correction agent.
