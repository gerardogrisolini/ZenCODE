# Why ZenCODE

Why this project exists and where it differs from other coding agents.

## Run anywhere

- Drive ZenCODE with any OpenAI-compatible API endpoint (OpenRouter, local servers, any `/v1` provider), or sign in with your existing **ChatGPT** or **Claude subscription** through the browser — no API key needed.
- macOS, Linux, and Windows (via WSL) with cloud providers or subscriptions.
- Runs on low-power ARM Linux boards such as a Raspberry Pi: model inference stays on the remote provider, so even a small single-board computer is enough to host the agent.

## Full control over tools

- Granular selection with `/tools`: decide exactly which tool groups are exposed (filesystem, shell, text, search, Git, memory, sub-agents, Xcode, Figma, features).
- Disable everything (`/tools none`) for minimal or read-only mode.
- Create new durable tools with the Builder and Dynamic Swift Features.

## Native Swift stack

- Natively compiled for Apple Silicon: no interpreted runtime or Node event loop.
- Strong typing and Swift concurrency: less fragility than JavaScript/Node stacks with large dependency trees.
- Smaller attack surface: a self-contained Swift package, no npm dependency chain.

## Performance

- Low client overhead: prompt assembly, tool dispatch, and streaming run in a single compiled Swift process, so the only network hop is the request to your chosen provider.
- Resume without re-work: sessions restore from on-disk snapshots and checkpoint trees, so continuing a conversation reuses the saved transcript and plan instead of rebuilding local state from scratch.
- Tiny footprint on modest hardware: compiled ahead of time to a native binary with no interpreter or Node runtime, ZenCODE uses only a few MB of RAM at idle. That makes it an ideal fit for constrained devices like a Raspberry Pi, where it stays fast and responsive while the heavy model work runs on the provider.

## Work environment integration

- ACP agent over stdio: connects to compatible clients including **Xcode 27** as a native coding agent with a dedicated profile.
- Xcode and Figma tools exposed via MCP when available.

## Agentic workflow

- Agent profiles (`Developer`, `Builder`, `Minimal`, `Xcode`, `Planner`, `Reviewer`, `Reporter`) with dedicated tools, skills, model, and instructions — see [agents.md](agents.md).
- `/plan` authored by one read-only `Planner`, `/review` delegated to read-only `Reviewer` sub-agents.
- `/workflow` plans and delegates every task to sub-agents on a dependency-aware task graph, with parallelism where safe, independent validation, and retry — the current agent stays as coordinator and final reviewer.
- Capability-based delegation: each profile's model bindings carry a capability score (1–10) and every task a complexity (1–10), so the coordinator can steer each unit of work to the lowest-capability sub-agent that still meets it — matching effort to task instead of picking by seniority. See [agents.md](agents.md#capability-routing).
- Dynamic Swift Features: the Builder generates reusable Swift packages as durable tools.
- Change tracking and `/undo` as a safety net.
- Saved sessions with checkpoint trees: per-project snapshots with branching, checkpoints, and in-place restore from any point; project `MEMORY.md` journal, `AGENTS.md` for durable guidance.
- Modular skills selectable per session, installable from GitHub or a local folder.

## Extras

- Remote control via Telegram and local voice tools (`/voice`), optional and enabled in setup.
- Simple installation via script.
