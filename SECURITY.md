# Security Policy

## Supported versions

ZenCODE is developed on `main` and released as `vX.Y.Z` tags. Security fixes
land on `main` and are shipped in the next release; only the latest release is
supported.

| Version | Supported |
| ------- | --------- |
| latest release | ✅ |
| older tags | ❌ |

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/gerardogrisolini/ZenCODE/security/advisories/new)
for this repository. That channel keeps the discussion confidential until a fix
is available.

Please include:

- affected version or commit, and the platform (macOS, Linux, or WSL);
- a description of the issue and its impact;
- reproduction steps or a proof of concept;
- any suggested mitigation.

You can expect an initial acknowledgement within a few days. Once the report is
confirmed, the fix and disclosure timeline are coordinated with the reporter.
Please allow a fix to ship before public disclosure.

## Scope

ZenCODE is a coding agent that executes tools on the user's machine and talks to
remote model providers. Reports are especially relevant for:

- persisted credential handling (see below);
- the tool authorization and approval system, including bypasses of the
  configured permission boundaries;
- sandbox or file-scope escapes in local file, patch, and shell tooling;
- the ACP bridge and the SwiftNIO HTTP/SSE/WebSocket transport;
- installer scripts and the release/ref pinning contract;
- feature executables and the MCP bridge.

## Credential storage

ZenCODE persists provider API keys, subscription credentials, and durable
approvals in its application-support manifests, protected by a centralized
filesystem boundary (`0700` directories, `0600` files, atomic writes, symlink
refusal).

This is filesystem hardening, **not** encryption and not an OS credential vault:
manifest payloads remain plaintext for the owning user and for any principal
that can act as that user or as root. The full threat model, its explicit
limits, and the migration seam for a future vault are documented in
[Docs/security.md](Docs/security.md). Reports pointing out weaknesses *within*
that stated model are in scope; the documented limits themselves are known.

## Model and content trust

Content retrieved from the web, from a page snapshot, or returned by a tool is
untrusted data, and model output can be influenced by it. Prompt-injection
findings are most useful when they show a concrete escalation, such as bypassing
tool authorization, exfiltrating credentials, or writing outside the approved
scope.
