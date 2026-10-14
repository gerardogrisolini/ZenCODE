# ZenVoice subscription bridge (private protocol v1)

`zen --voice-bridge` is a standalone composition-root mode. It bypasses interactive setup, the agent/task runner, ACP, Codex and API-key fallback. It requires pipe stdin/stdout; all additional CLI arguments are rejected. The app remains a separate macOS 14+ target without a ZenCODECore dependency. A compatible installed/built `zen` supplies the provider implementation and its own OS requirements.

## Trust and wire boundary

UTF-8 JSON Lines, one object per line, version `1`. Maximum line 131072 bytes, SDP 65536 bytes, command text 16000 UTF-8 bytes. Unknown fields/commands, duplicate request IDs, bad ordering, partial EOF, overflows and write failures fail closed. Stdout is IPC data, not a log; stderr must not be exposed by the app. No credential, account ID, header, API key or browser cookie crosses the pipe. SDP contains network/media negotiation data and crosses only RAM IPC; the app passes it to trusted JavaScript as an argument, never source interpolation.

Client commands (each requires a fresh `id`):

- `open`: `{version,id,command:"open",sdp,projects}`. Exactly one per process. Projects are explicit app allowlist paths used as model context, not task-runner configuration.
- `speak`: `{version,id,command:"speak",text}`. V3 `session.context.append` with `speakable` channel.
- `delegationResult`: `{version,id,command:"delegationResult",delegationID,text}`. Only an outstanding provider delegation, once; maps to `delegation.context.append`. Results are untrusted data.
- `close`: `{version,id,command:"close"}`. EOF and signals also close/cancel. No generic raw-event, input-audio, command execution, arbitrary URL or refresh operation exists.

Server events: `ready`; `opened` with matching request `id` and response `sdp`; `session`; `delegation` with opaque provider `id` and bounded `text`; `error` with stable safe `code` and optional HTTP `status`; `closed` with optional hangup `status` and `hangup_accepted`/`remote_unconfirmed`. No raw provider error body or transcript is logged. Model-generated delegation text is parsed strictly by the app; it cannot select permission options. No tokens are sent to WebKit.

## Auth, network and lifecycle

The standard ChatGPT credential store provides a serialized snapshot and normal permission hardening. Values are never saved/refreshed by the bridge. Environment credential overrides are rejected; expiry is checked from stored date and JWT `exp`/account consistency. JWT parsing is not signature verification or an entitlement check. Missing/expired login asks the user to renew it through normal `zen` setup; never falls back to API billing.

SIWC POST `https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas` uses V3 session model `gpt-live-1-codex`, voice `cove`, honest client metadata and `openai-alpha: quicksilver=v2`. HTTP and sideband `wss://api.openai.com/v1/live/<call_id>` use the same bearer/account. No redirects or automatic retries. The call ID is retained as soon as successful headers arrive, including when collecting the SDP subsequently fails. Media is WebRTC, not sideband `input_audio.append` (the deployed server rejects that event).

Each process owns one SwiftNIO transport/event loop. Close cancels opening/receiving, attempts bounded `session.close` and socket close, then one official `POST https://api.openai.com/v1/realtime/calls/<id>/hangup`, and shuts down NIO. Cleanup runs outside parent cancellation. No invented backend hangup endpoint. A lost create response/ID or failed hangup leaves remote state unconfirmed. Stdout writes are serialized and nonblocking with a five-second deadline; SIGPIPE is ignored in this dedicated process.

The app uses a local non-persistent WKWebView, constrained navigation/CSP and capture permissions: only a main-frame microphone request from its trusted origin during explicit activation may be granted. Remote ICE candidates must be bounded public literal addresses; no third-party STUN/TURN servers are configured. Native mute precedes async peer/bridge teardown. Audio playback/VAD does not manufacture API receipts. Subscription ACP permissions use a menu/modal explicit `allow_once`/deny fence keyed to client, request and activation with timeout; API vocal confirmations are unchanged.

## Validation boundaries

Unit/local fixtures cover protocol allowlists, authentication failure without fallback, quota/403 handling, cancellation after response headers, teardown under a stalled socket close, delegation dedup, UTF-8 limits, explicit permission correlation and stdin/stdout failure. The coalesced HTTP101/WS-frame regression must pass with `leftOverBytesStrategy: .forwardBytes`.

Builds and fixtures do not certify physical audio, user TCC/signing, provider availability, quote windows or sustained duration. Interactive app activation is user-controlled; do not substitute a diagnostic handshake for an audio acceptance test.
