//
//  ZenCODECommandLineRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Runs the interactive setup owned by the executable composition root. The
/// return value says whether a usable configuration remains available for
/// rebuilding the chat.
public typealias ZenCODEInteractiveSetupHandler = @Sendable () async throws -> Bool

public enum ZenCODECommandLineRunner {
    /// Meta-commands that keep their normal textual behavior and exit code.
    /// When one of them is present, `--jsonl` is ignored: the meta-command
    /// wins and the JSONL stream never replaces its human-readable output.
    private static let metaCommandOptions: Set<String> = [
        "--help", "-h", "--version", "--doctor", "--install-features"
    ]

    /// Whether `--jsonl` owns stdout for this invocation. It is deliberately
    /// false whenever a meta-command is present, so meta-commands preserve
    /// their textual output and exit semantics. `--install-features=id` and
    /// friends are recognized through their `=`-form too.
    public static func jsonlIsActive(arguments: [String]) -> Bool {
        let options = arguments.dropFirst()
        guard options.contains("--jsonl") else {
            return false
        }
        let hasMetaCommand = options.contains { option in
            metaCommandOptions.contains(option)
                || (option.hasPrefix("--install-features")
                    && option.dropFirst("--install-features".count).first == "=")
        }
        return !hasMetaCommand
    }
    public static func main(
        setupHandler: ZenCODEInteractiveSetupHandler? = nil,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async {
        await main(
            arguments: CommandLine.arguments,
            setupHandler: setupHandler,
            backendFactory: backendFactory
        )
    }

    public static func main(
        arguments rawArguments: [String],
        setupHandler: ZenCODEInteractiveSetupHandler? = nil,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async {
        var requestedJSONL = false
        var jsonlRunnerStarted = false
        do {
            SwiftPMResourceBundleDirectory.configure()

            let sanitizedArguments = ZenCODECommandLineArgumentSanitizer.sanitized(rawArguments)
            requestedJSONL = jsonlIsActive(arguments: sanitizedArguments)
            if ZenCODEDoctorRunner.shouldRun(arguments: sanitizedArguments) {
                // Non-interactive diagnostics: print a redacted report and exit.
                // Handled before configuration parsing so it never starts setup
                // or is rejected as an unknown argument. A meta-command always
                // wins over --jsonl (see `jsonlIsActive(arguments:)`).
                Foundation.exit(ZenCODEDoctorRunner.run())
            }
            var configuration = try AgentConfiguration(
                arguments: sanitizedArguments
            )
            if configuration.printHelp {
                AgentOutput.standardOutput.writeString(AgentConfiguration.helpText)
                return
            }
            if configuration.printVersion {
                AgentOutput.standardOutput.writeString("ZenCODE \(agentVersion)\n")
                return
            }

            // Chat may use `/dev/tty` when stdin is redirected, but headless
            // context input must be classified from stdin itself.
            let stdinIsTerminal = isatty(STDIN_FILENO) == 1
            let interactiveInputAvailable = TerminalRawInput.supportsInteractiveInput()
            let resolvedRunMode = configuration.resolvedRunMode(
                stdinIsTerminal: interactiveInputAvailable
            )

            switch resolvedRunMode {
            case .headless:
                AgentOutput.silenceInheritedProcessOutput()
                if configuration.jsonl {
                    AgentOutput.silenceAllStandardError()
                }
                let prompt = try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: configuration.headlessPrompt,
                    stdinIsTerminal: stdinIsTerminal
                )
                let permissionAuthorizer = LocalExecPermissionAuthorizer()
                jsonlRunnerStarted = configuration.jsonl
                try await AgentRuntimeLauncher.runHeadless(
                    configuration: configuration,
                    prompt: prompt,
                    permissionAuthorizer: permissionAuthorizer,
                    backendFactory: backendFactory
                )
            case .chat:
                AgentOutput.silenceInheritedProcessOutput()
                let permissionAuthorizer = LocalExecPermissionAuthorizer()
                let sessionRunner = AgentCoreSessionRunner(
                    defaultToolAuthorizationHandler: { request in
                        await permissionAuthorizer.authorize(request)
                    },
                    backendFactory: backendFactory
                )
                var resumeSnapshot: TerminalChatResumeSnapshot?
                do {
                    while true {
                        let outcome = try await AgentRuntimeLauncher.runTerminalChat(
                            configuration: configuration,
                            stdinIsTerminal: interactiveInputAvailable,
                            sessionRunner: sessionRunner,
                            permissionAuthorizer: permissionAuthorizer,
                            runtimeSetupResumeSnapshot: resumeSnapshot
                        )
                        switch outcome {
                        case .exited:
                            await sessionRunner.shutdown()
                            return
                        case let .setupRequested(snapshot):
                            await sessionRunner.shutdownBackendKeepingExternalTools()
                            guard let setupHandler else {
                                throw ZenCODECommandLineRunnerError.setupUnavailable
                            }
                            guard try await setupHandler() else {
                                await sessionRunner.shutdown()
                                return
                            }
                            await permissionAuthorizer.reloadPersistedPermissions()
                            await sessionRunner.resetLocalExecAccessMode()
                            resumeSnapshot = snapshot
                            configuration = try AgentConfiguration(
                                arguments: sanitizedArguments
                            )
                        }
                    }
                } catch {
                    await sessionRunner.shutdown()
                    throw error
                }
            case .acp:
                AgentOutput.silenceInheritedProcessError()
                await AgentRuntimeLauncher.runACP(
                    configuration: configuration,
                    backendFactory: backendFactory
                )
            }
        } catch {
            if requestedJSONL {
                if !jsonlRunnerStarted {
                    ZenCODEHeadlessJSONLProtocol.writeFramedError(error)
                }
            } else {
                AgentOutput.standardError.writeString(
                    "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
                )
            }
            Foundation.exit(1)
        }
    }

    public static func shouldRunAsCommandLine(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard let executablePath = arguments.first else {
            return false
        }
        let sanitizedArguments = ZenCODECommandLineArgumentSanitizer.sanitized(arguments)

        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
        guard executableURL.lastPathComponent == "ZenCODE" else {
            return false
        }

        if sanitizedArguments.dropFirst().contains(where: isCommandLineOption(_:)) {
            return true
        }

        if !executableURL.path.contains(".app/Contents/MacOS/") {
            return true
        }

        if sanitizedArguments.count == 1,
           ZenCODECommandLineArgumentSanitizer.containsCocoaLaunchArguments(arguments) {
            return false
        }

        return isatty(STDIN_FILENO) == 1
    }

    private static func isCommandLineOption(_ argument: String) -> Bool {
        argument == "-h"
            || argument == "--help"
            || argument == "--version"
            || argument == "--doctor"
            || argument == "--model"
            || argument == "--agent"
            || argument == "--acp"
            || argument == "-p"
            || argument == "--prompt"
            || argument == "--jsonl"
            || argument == "--working-directory"
            || argument == "--skills"
            || argument == "--max-tool-rounds"
            || argument == "--max-output-tokens"
    }
}

private enum ZenCODECommandLineRunnerError: LocalizedError {
    case setupUnavailable

    var errorDescription: String? {
        switch self {
        case .setupUnavailable:
            return "Interactive setup is unavailable in this executable."
        }
    }
}
