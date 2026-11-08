//
//  ZenCODESetupCommand.swift
//  ZenCODE
//

import Foundation

/// Interactive `zen --setup` command.
///
/// It is the only way to open the interactive setup: no mode starts it by
/// itself, and every mode except ACP stops with
/// ``ZenCODESetupRequirement/notConfiguredMessage`` while ZenCODE is not
/// configured. It requires an interactive terminal, accepts no other option,
/// never starts a chat, and ends when the setup ends; the exit status tells
/// whether ZenCODE is configured.
package enum ZenCODESetupCommand {
    package static let option = "--setup"

    /// One run of the interactive setup, to its outcome.
    typealias SetupRunner = @Sendable () async throws -> SetupOutcome
    /// Whether ZenCODE is configured now.
    typealias ConfigurationCheck = @Sendable () -> Bool

    /// Whether the sanitized arguments request the setup command.
    package static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    /// Checks that `arguments` (the executable at index 0) contain only
    /// `--setup`, which may be repeated.
    ///
    /// - Throws: `AgentConfigurationError.conflictingOptions("--setup",
    ///   argument)` for the first other argument.
    package static func validateArguments(_ arguments: [String]) throws {
        if let argument = arguments.dropFirst().first(where: { $0 != option }) {
            throw AgentConfigurationError.conflictingOptions(option, argument)
        }
    }

    /// Runs the interactive setup until it ends and returns whether ZenCODE is
    /// configured then. A setup that reset the configuration or replaced the
    /// support directory with a backup is opened again, since what it left
    /// must be configured from scratch.
    ///
    /// - Throws: What the setup throws, for example when the terminal is not
    ///   interactive.
    package static func run() async throws -> Bool {
        try await run(
            setupRunner: { try await ZenCODESetupRunner.run() },
            isConfigured: { !ZenCODESetupRequirement.isRequired() }
        )
    }

    /// ``run()`` over `setupRunner` and `isConfigured`, for tests.
    static func run(
        setupRunner: SetupRunner,
        isConfigured: ConfigurationCheck
    ) async throws -> Bool {
        while true {
            switch try await setupRunner() {
            case .configured, .cancelled:
                // A cancelled setup may still leave a valid configuration
                // (for example, one that already existed).
                return isConfigured()
            case .reset, .dataReplaced:
                // A reset removed the active configuration, an imported
                // backup replaced it: offer the setup again in the same
                // process; a cancel then ends it with the check above.
                continue
            }
        }
    }
}
