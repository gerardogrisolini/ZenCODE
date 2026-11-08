//
//  ZenCODESetupRequirement.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Shared startup gate for the executable composition root. A decodable
/// manifest is not sufficient by itself: the runtime also needs at least one
/// model and the remaining required support files must be ready.
///
/// No mode opens the setup by itself: `zen --setup` (`ZenCODESetupCommand`)
/// is the only way in. Every mode except ACP stops at the gate with
/// ``notConfiguredMessage``; ACP still answers `initialize`, so the client can
/// offer its terminal setup method, which launches `zen --setup`.
public enum ZenCODESetupRequirement {
    /// What a launch stopped by the gate prints on standard error, without the
    /// `ZenCODE: ` prefix, and what its JSON Lines error record carries
    /// (``NotConfiguredError``). The backticks are part of the text.
    package static let notConfiguredMessage =
        "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again."

    /// The error of a launch stopped by the gate. Its description is
    /// ``notConfiguredMessage``, and the JSON Lines protocol frames it with
    /// that same message in the `configuration` category.
    package struct NotConfiguredError: LocalizedError, Sendable, Equatable {
        package init() {}

        package var errorDescription: String? {
            ZenCODESetupRequirement.notConfiguredMessage
        }
    }

    public static func isRequired(
        manifest: AgentSettingsManifest?,
        status: SetupStatus
    ) -> Bool {
        manifest?.models.isEmpty != false || status.requiresSetup
    }

    /// Evaluates the gate against the persisted configuration of this process:
    /// the same rule the executable applies before it launches any mode.
    package static func isRequired() -> Bool {
        let manifest = try? AgentSettingsManifestStore.loadRequired(
            from: AgentSettingsManifestStore.settingsURL()
        )
        return isRequired(manifest: manifest, status: ZenInspector.status())
    }

    /// Whether the gate applies to a launch with `arguments` (the executable
    /// at index 0, already validated by `AgentConfiguration.validateArguments`)
    /// and `environment`: for every mode except ACP, which must answer
    /// `initialize` even without a configuration.
    ///
    /// The meta-commands (`--help`, `--version`, `--doctor`,
    /// `--install-features`), `--setup` and the macOS `--ui` are not modes:
    /// the executable handles them before it asks.
    package static func gateApplies(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !runsACP(arguments: arguments, environment: environment)
    }

    /// The options that take the next argument as their value, which is
    /// therefore never read as an option. `-p`, `--prompt` and `-f` also select
    /// a mode other than ACP (``otherModeOptions``).
    private static let valueOptions: Set<String> = [
        "--model", "--agent", "--working-directory", "--skills",
        "--max-tool-rounds", "--max-output-tokens",
        "-p", "--prompt", "-f"
    ]

    /// The options that select a mode other than ACP.
    private static let otherModeOptions: Set<String> = [
        "-p", "--prompt", "-f", "--tui", "--telegram", "--jsonl"
    ]

    /// Whether the launch runs ACP, with the precedence of the configuration
    /// parser: `--acp` selects it; otherwise `ZENCODE_AGENT_MODE=acp` (trimmed,
    /// case-insensitive) selects it unless an option selects another mode
    /// (`--tui`, `--telegram`, `-p`/`--prompt`, `-f`, `--jsonl`), which wins
    /// over the environment.
    static func runsACP(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        var selectsOtherMode = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--acp" {
                return true
            }
            if otherModeOptions.contains(argument) {
                selectsOtherMode = true
            }
            if valueOptions.contains(argument) {
                index += 1
            }
            index += 1
        }
        guard !selectsOtherMode else {
            return false
        }
        return environment["ZENCODE_AGENT_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == AgentRunMode.acp.rawValue
    }
}
