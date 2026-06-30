# Why ZenCODE
This document summarizes the strengths of `ZenCODE`, my motivations for writing it, and why it is often a better choice than other agents.

## Strengths
### Execution and privacy
- **Local-first on Apple Silicon**: with `zen --mlx`, inference runs
  entirely on the local MLX runtime, in the same process, **with no HTTP server
  and no remote provider**. Your code never leaves the machine.
- **Dual mode**: the same agent works with configurable remote providers or in
  fully local mode, chosen based on cost and privacy.
- **Pragmatic cross-platform support**: macOS with local MLX; Linux and Windows
  (via WSL) in remote-only mode, without pulling Metal dependencies into the
  build.

### Full control over tools
- **Granular selection with `/tools`**: you decide exactly which tool groups
  (filesystem, shell, text, search, Git, memory, orchestration, Xcode, Figma,
  features) are exposed to the model, using `all`, `none`, tool name, package
  name, or number.
- **You can disable everything** (`/tools none`) and work in a minimal or
  read-only mode, minimizing the agent's action surface.
- **And create new ones**: with the Builder and Dynamic Swift Features, the agent
  generates durable, reusable tools that can be enabled or disabled at will —
  full control both by subtraction and by addition.

### Native Swift stack
- **Performance**: natively compiled code for Apple Silicon, with no interpreted
  runtime or Node event loop.
- **Stability**: strong typing and Swift concurrency, less fragility than
  JavaScript/Node stacks with large dependency trees.
- **Security**: smaller attack surface and no npm dependency chain; a
  self-contained Swift package.

### Architecture and performance
- **Persistent on-disk KV cache** (`~/.zencode/mlx/KVCaches/`): a resumed
  conversation does not re-prefill the entire transcript. The session key is
  derived stably from the system prompt and the first message, so even stateless
  ACP clients reuse the cache across reconnections.
- **Native Swift Package**: direct integration with the Apple ecosystem, without
  heavy runtimes.

### Integration into the work environment
- **ACP agent over stdio**: connects to compatible clients, including **Xcode 27**
  as a native coding agent with a dedicated profile.
- **Xcode and Figma tools** exposed via MCP when available, in addition to
  filesystem, shell, text, search, Git, and memory.

### Agentic workflow
- **Agent profiles** (`Default`, `Builder`, `Minimal`, `Xcode`, `Reviewer`) with
  dedicated tools, skills, model, and instructions, switchable within a session.
- **Sub-agents and `/review`**: read-only review delegated to `Reviewer`
  sub-agents in `isolationMode report`, runnable in parallel, with a read-only
  allowlist restricted to the session's tracked changes.
- **Dynamic Swift Features**: the Builder generates reusable Swift packages as
  durable tools, run out-of-process over a JSON stdin/stdout protocol.
- **Change tracking and `/undo`**: `/changes`, `/changes diff`, and restoring the
  agent's latest changes as a safety net.
- **Saved sessions and structured memory**: per-project snapshots, a clear
  separation between project `MEMORY.md` (journal) and the global index, plus
  `AGENTS.md` for operating rules.
- **Modular skills** selectable per session, installable from GitHub or a local
  folder.

### Extras
- **Remote control via Telegram** and **local voice tools** (`/voice`, `/speak`),
  optional and enabled in setup.
- **Simple installation** via script.

## Why it is better than other agents

1. **Full and reversible control over tools**: unlike agents with fixed or opaque tool sets, here you enable and disable each group, reset everything with `/tools none`, and add custom tools as durable Swift Features.
2. **Swift vs Node**: because it is written entirely in Swift, `ZenCODE` delivers **native performance, greater stability, and a smaller security surface** than apps built on Node.js, which rely on an interpreted runtime and large npm dependency chains.
3. **Real privacy and zero inference cost**: in-process local MLX inference eliminates cloud calls and code leakage, whereas many agents depend on paid remote APIs.
4. **No HTTP overhead locally**: the model runs in the same process, avoiding the serialization of calls over a local server.
5. **Efficient session continuity**: the persistent KV cache with a content-derived key drastically reduces re-prefill, even for statelessients.
6. **Native Xcode integration via ACP**: it fits directly into the Apple workflow as an Xcode 27 coding agent.
7. **Durable extensibility**: the agent not only uses tools but **creates new ones** as reusable Swift packages shared across sessions.
8. **Review and orchestration safe by design**: review sub-agents are read-only and limited to the current session's changes, reducing the risk of unwantedits.
9. **Change safety**: change tracking and a dedicated `/undo` for the agent'sits.
10. **Memory with separated responsibilities**: project journal, global index, and operating rules kept distinct, for cleaner context resumption.
