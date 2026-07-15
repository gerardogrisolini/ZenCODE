# Why ZenCODE

Why this project exists and where it differs from other coding agents.

## Run anywhere

- Drive ZenCODE with any OpenAI-compatible API endpoint (OpenRouter, local servers, any `/v1` provider), sign in with your existing **ChatGPT** or **Claude subscription** through the browser — no API key needed — or run fully on-device with `zen --mlx` / `zen --ds4`.
- With `zen --mlx`, inference runs in-process on the local MLX runtime: no HTTP server, no remote provider, code never leaves the machine.
- macOS with cloud, subscriptions, or local MLX/DS4; Linux and Windows (via WSL) with cloud providers, subscriptions, or local DS4 — without pulling Metal dependencies into the build.

## Full control over tools

- Granular selection with `/tools`: decide exactly which tool groups are exposed (filesystem, shell, text, search, Git, memory, sub-agents, Xcode, Figma, features).
- Disable everything (`/tools none`) for minimal or read-only mode.
- Create new durable tools with the Builder and Dynamic Swift Features.

## Native Swift stack

- Natively compiled for Apple Silicon: no interpreted runtime or Node event loop.
- Strong typing and Swift concurrency: less fragility than JavaScript/Node stacks with large dependency trees.
- Smaller attack surface: a self-contained Swift package, no npm dependency chain.

## Performance

- Persistent on-disk KV cache: a resumed conversation does not re-prefill the entire transcript. The session key is derived stably from the system prompt and first message, so even stateless ACP clients reuse the cache.
- No HTTP overhead locally: the model runs in the same process.

## Work environment integration

- ACP agent over stdio: connects to compatible clients including **Xcode 27** as a native coding agent with a dedicated profile.
- Xcode and Figma tools exposed via MCP when available.

## Agentic workflow

- Agent profiles (`Developer`, `Builder`, `Minimal`, `Xcode`, `Planner`, `Reviewer`, `Reporter`) with dedicated tools, skills, model, and instructions — see [agents.md](agents.md).
- `/plan` authored by one read-only `Planner`, `/review` delegated to read-only `Reviewer` sub-agents.
- Dynamic Swift Features: the Builder generates reusable Swift packages as durable tools.
- Change tracking and `/undo` as a safety net.
- Saved sessions and structured memory: per-project snapshots, project `MEMORY.md` journal, `AGENTS.md` for durable guidance.
- Modular skills selectable per session, installable from GitHub or a local folder.

## Extras

- Remote control via Telegram and local voice tools (`/voice`), optional and enabled in setup.
- Simple installation via script.
