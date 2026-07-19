# Xcode 27 ACP setup

Xcode 27 can run `zen` as an ACP stdio coding agent. Use the dedicated `Xcode` agent profile so Xcode sessions get the Xcode-native tool set by default.

## Prerequisites

1. Install `ZenCODE` and run setup at least once:

   ```bash
   zen --setup
   ```

2. Make sure the recommended agents exist. The setup can create `Developer`, `Builder`, `Minimal`, `Xcode`, `Planner`, `Reviewer`, and `Reporter`.
3. Verify the executable path:

   ```bash
   which zen
   ```

   The default script install usually returns `/usr/local/bin/zen`.

## Add `ZenCODE` in Xcode

1. Open **Xcode 27**.
2. Open **Xcode > Settings…**.
3. Select **Intelligence**.
4. In **Coding Agents**, click **Add an Agent**.

![Xcode Intelligence settings showing Coding Agents](Images/xcode-intelligence-agents.png)

## Configure the agent

In the agent editor, set:

- **Name**: `ZenCODE`
- **Executable**: the full path returned by `which zen`, for example `/usr/local/bin/zen`
- **Arguments**: `--acp`
- **Interpreter**: leave empty

Then add this environment variable:
- **Name**: `ZENCODE_AGENT_NAME`
- **Value**: `Xcode`

![Xcode agent arguments and environment configuration](Images/xcode-agent-arguments.png)

Save the agent.

Xcode 27 beta 3 may ask you to authenticate a custom ACP agent even when the agent does not require that step. Choose **Continue with ZenCODE**. This only acknowledges Xcode’s compatibility step; it does not configure or authenticate a model provider.

## Recommended configuration

Use this final configuration:

```text
Name: ZenCODE
Executable: /usr/local/bin/zen
Arguments: --acp
Interpreter: <empty>
Environment:
  ZENCODE_AGENT_NAME=Xcode
```

## Troubleshooting

- **Xcode cannot start the agent**: use an absolute executable path, not just `zen`.
- **The wrong agent profile is selected**: check that `ZENCODE_AGENT_NAME` is exactly `Xcode`.
- **Xcode tools are unavailable**: keep Xcode open and approve any MCP/automation prompt shown by Xcode.
- **No model is configured**: run `zen --setup` in Terminal and configure at least one provider/model.
- **“This provider requires authentication” in Xcode 27 beta 3**: update ZenCODE, select **Continue with ZenCODE**, then retry the session. This is an Xcode ACP compatibility acknowledgment, not provider authentication.
