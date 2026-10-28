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
            // While ZenCODE has no usable configuration, `--acp` must still
            // answer `initialize` so the client can offer the terminal setup
            // method. That path never reads the persisted configuration: the
            // client relaunches the agent after the setup, so no hot reload.
            let unconfiguredACPConfiguration = try Self.unconfiguredACPConfiguration(
                arguments: sanitizedArguments
            )
            var configuration = try unconfiguredACPConfiguration
                ?? AgentConfiguration(arguments: sanitizedArguments)
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
                if let recipient = ZenCronMailDelivery.recipient(
                    environment: ProcessInfo.processInfo.environment,
                    standardOutputIsTerminal: AgentOutput.standardOutputIsTerminal
                ) {
                    let succeeded = await runHeadlessDeliveringByMail(
                        to: recipient,
                        configuration: configuration,
                        requestedJSONL: requestedJSONL,
                        stdinIsTerminal: stdinIsTerminal,
                        backendFactory: backendFactory
                    )
                    if !succeeded {
                        Foundation.exit(1)
                    }
                    return
                }
                if configuration.jsonl {
                    AgentOutput.silenceAllStandardError()
                }
                let prompt = try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: configuration.headlessPrompt,
                    promptFile: configuration.headlessPromptFile,
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
                    backendFactory: backendFactory,
                    setupRequired: unconfiguredACPConfiguration != nil
                )
            }
        } catch {
            if requestedJSONL {
                if !jsonlRunnerStarted {
                    ZenCODEHeadlessJSONLProtocol.writeFramedError(error)
                }
            } else {
                AgentOutput.standardError.writeString(failureMessage(for: error))
            }
            Foundation.exit(1)
        }
    }

    /// Whether ACP was requested: `--acp` among the arguments, or
    /// `ZENCODE_AGENT_MODE=acp` (trimmed, case-insensitive).
    static func requestsACP(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.dropFirst().contains("--acp")
            || environment["ZENCODE_AGENT_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == AgentRunMode.acp.rawValue
    }

    /// The configuration for an ACP launch that must not read any persisted
    /// setting because ZenCODE is not set up yet, or `nil` when the ordinary
    /// configuration applies.
    ///
    /// Help and version requests are left to the ordinary path, which prints
    /// them without ever needing a configuration. The persisted configuration
    /// is only consulted for the setup gate, with the same rule the executable
    /// applies before the interactive setup (`ZenCODESetupRequirement`).
    private static func unconfiguredACPConfiguration(
        arguments: [String]
    ) throws -> AgentConfiguration? {
        guard requestsACP(arguments: arguments) else {
            return nil
        }
        let configuration = try AgentConfiguration.withoutPersistedConfiguration(
            arguments: arguments
        )
        guard configuration.resolvedRunMode(stdinIsTerminal: false) == .acp,
              !configuration.printHelp,
              !configuration.printVersion,
              ZenCODESetupRequirement.isRequired() else {
            return nil
        }
        return configuration
    }

    /// What a failed text-mode run prints on standard error.
    static func failureMessage(for error: Error) -> String {
        "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
    }

    /// Runs a headless turn started by cron with a deliverable `MAILTO` (see
    /// `ZenCronMailDelivery`) and sends its output through Mail.app.
    ///
    /// The run is the ordinary one: only what it would print is captured
    /// instead, failures included, with the same bytes the ordinary path
    /// prints. That is what the fallback prints when Mail.app cannot send. The
    /// message itself is built from the capture by `ZenCronMailDelivery`: a
    /// text-mode run becomes a plain-text body with the Markdown answer
    /// attached as a `.md` file.
    ///
    /// - Returns: Whether the run succeeded; the delivery outcome never
    ///   changes the exit status.
    private static func runHeadlessDeliveringByMail(
        to recipient: String,
        configuration: AgentConfiguration,
        requestedJSONL: Bool,
        stdinIsTerminal: Bool,
        backendFactory: AgentRuntimeBackendFactory?
    ) async -> Bool {
        let fallbackOutput = ZenCronFallbackOutput.duplicatingAgentOutput()
        // Anything that still reached a real stream would be cron output, and
        // cron would queue it as a second message that never leaves the Mac.
        AgentOutput.silenceAllStandardError()

        let output = ZenCronCapturedOutput()
        var jsonlRunnerStarted = false
        var succeeded = true
        do {
            let prompt = try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: configuration.headlessPrompt,
                promptFile: configuration.headlessPromptFile,
                stdinIsTerminal: stdinIsTerminal
            )
            let permissionAuthorizer = LocalExecPermissionAuthorizer()
            jsonlRunnerStarted = configuration.jsonl
            try await AgentRuntimeLauncher.runHeadless(
                configuration: configuration,
                prompt: prompt,
                permissionAuthorizer: permissionAuthorizer,
                backendFactory: backendFactory,
                jsonlSink: { data in output.append(data) },
                textSink: { text in output.append(text) }
            )
        } catch {
            succeeded = false
            // Mirrors the catch of `main`: a started JSONL runner has already
            // written its terminal error record.
            if requestedJSONL {
                if !jsonlRunnerStarted,
                   let record = ZenCODEHeadlessJSONLProtocol.framedErrorData(error) {
                    output.append(record)
                }
            } else {
                output.append(failureMessage(for: error), to: .standardError)
            }
        }

        let deliveredAt = Date()
        let timeZone = TimeZone.current
        await ZenCronMailDelivery.deliver(
            output.chunks,
            // What the run wrote decides it: a JSONL run is never converted.
            format: configuration.jsonl || requestedJSONL ? .jsonl : .text,
            to: recipient,
            subject: ZenCronMailDelivery.subject(
                succeeded: succeeded,
                promptFile: configuration.headlessPromptFile,
                prompt: configuration.headlessPrompt,
                date: deliveredAt,
                timeZone: timeZone
            ),
            attachmentName: ZenCronMailDelivery.attachmentFileName(
                promptFile: configuration.headlessPromptFile,
                prompt: configuration.headlessPrompt,
                date: deliveredAt,
                timeZone: timeZone
            ),
            attachmentsDirectory: ZenCronMailDelivery.defaultAttachmentsDirectory,
            sender: ZenCronFeatureMailSender(workingDirectory: configuration.workingDirectory),
            writeStandardOutput: { data in fallbackOutput.standardOutput.write(data) },
            writeStandardError: { data in fallbackOutput.standardError.write(data) }
        )
        return succeeded
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
            || argument == "-f"
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
