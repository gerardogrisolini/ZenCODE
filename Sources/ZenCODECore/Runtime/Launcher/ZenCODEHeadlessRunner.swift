//
//  ZenCODEHeadlessRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Minimal lifecycle surface used by the headless turn executor. Production
/// delegates to `AgentCoreSessionRunner`; tests can supply a controlled actor
/// without replacing the CLI or weakening the real session composition. The
/// turn itself runs through the shared ``ChatSessionController``.
protocol ZenCODEHeadlessSessionRunning: ChatSessionRuntime {
    /// Creates the session and installs its prompt-skill selection.
    func headlessCreateSession(
        configuration: AgentCoreSessionConfiguration,
        promptSkills: [PromptSkill]
    ) async throws
    func headlessCloseSession(id: String) async throws
    func headlessShutdown() async
}

extension AgentCoreSessionRunner: ZenCODEHeadlessSessionRunning {
    /// Mirrors `TerminalChat.createCurrentSession()`: `createSession` installs
    /// an empty session-scoped skill provider, so the selection is applied
    /// right after it. Without this step a headless turn never sees the
    /// selected prompt skills.
    func headlessCreateSession(
        configuration: AgentCoreSessionConfiguration,
        promptSkills: [PromptSkill]
    ) async throws {
        try await createSession(configuration: configuration)
        await updatePromptSkillSelection(
            promptSkills,
            sessionID: configuration.sessionID
        )
    }

    func headlessCloseSession(id: String) async throws {
        try await closeSessionThrowing(id: id)
    }

    func headlessShutdown() async {
        await shutdown()
    }
}

/// A headless session as composed by ``ChatSessionController``: the session
/// configuration and the prompt skills selected for it.
struct ZenCODEHeadlessSession: Sendable {
    let configuration: AgentCoreSessionConfiguration
    let promptSkills: [PromptSkill]
}

/// Executes one non-interactive text turn without starting the terminal UI.
public enum ZenCODEHeadlessRunner {
    public typealias TextSink = @Sendable (String) -> Void

    /// Resolves the headless instruction from `-p`, `-f`, or both, and appends
    /// piped stdin as additional context.
    ///
    /// - A prompt file alone is the instruction. Together with an inline prompt
    ///   it follows the inline text as "Additional context from file".
    /// - The file is read before stdin, so an unreadable file fails fast
    ///   without consuming piped input.
    /// - Without an inline prompt and without a prompt file, `noPrompt` is
    ///   thrown before stdin is read.
    public static func prompt(
        inlinePrompt: String?,
        promptFile: String? = nil,
        stdin: FileHandle = .standardInput,
        stdinIsTerminal: Bool
    ) throws -> String {
        guard inlinePrompt != nil || promptFile != nil else {
            throw ZenCODEHeadlessRunnerError.noPrompt
        }
        let fileText = try promptFile.map { try ZenCODEPromptFile.read(path: $0) }
        let stdinText = stdinIsTerminal
            ? ""
            : String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        var instruction = inlinePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let fileText {
            instruction = inlinePrompt == nil
                ? fileText
                : "\(instruction)\n\nAdditional context from file:\n\(fileText)"
        }
        let prompt = stdinText.isEmpty
            ? instruction
            : "\(instruction)\n\nAdditional context from stdin:\n\(stdinText)"
        guard !prompt.isEmpty else {
            throw ZenCODEHeadlessRunnerError.noPrompt
        }
        return prompt
    }

    /// Uses the normal Core session composition while deliberately omitting the
    /// TUI lifecycle, streaming chrome, setup UI, and interactive consent UI.
    /// `configuration.jsonl` is the sole source of truth for output mode.
    ///
    /// The sinks receive what would otherwise be printed on standard output
    /// (nil prints it), so a caller can capture the run's output, as Mail.app
    /// delivery of a scheduled run does.
    @TerminalChatActor
    public static func run(
        configuration: AgentConfiguration,
        prompt: String,
        permissionAuthorizer: LocalExecPermissionAuthorizer,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        jsonlSink: ZenCODEHeadlessJSONLWriter.Sink? = nil,
        textSink: TextSink? = nil
    ) async throws {
        let sessionRunner = AgentCoreSessionRunner(
            // This path never opens or reads a terminal consent dialog. It still
            // honors persisted approvals and tools which do not require consent.
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorizeNonInteractively(request)
            },
            backendFactory: backendFactory
        )
        let session = await makeSession(
            configuration: configuration,
            sessionRunner: sessionRunner
        )
        try await runTurn(
            configuration: configuration,
            prompt: prompt,
            sessionRunner: sessionRunner,
            sessionConfiguration: session.configuration,
            promptSkills: session.promptSkills,
            consentAuthorizer: permissionAuthorizer.consentAuthorizer,
            jsonlSink: jsonlSink,
            textSink: textSink
        )
    }

    /// Composes the headless session configuration through the same
    /// ``ChatSessionController`` composition used by the interactive session,
    /// without a terminal.
    ///
    /// The interactive session applies the selected agent profile (its tool
    /// selection and prompt skills) when it starts. Applying it here is what
    /// grants the profile's tools and skills to the session: without it the
    /// allowlist would hold only the intrinsic prompt-skill tools and no skill
    /// would be selected. The skills always come from the profile: `--skills`
    /// / `ZENCODE_AGENT_SKILLS` are an interactive startup selection and are
    /// deliberately not applied here. Profile application has no output, and
    /// tool authorization is untouched: consent-requiring actions still go
    /// through the non-interactive authorizer.
    ///
    /// The prompt carries no response-language section, as for an interactive
    /// session before its first prompt locks a language.
    @TerminalChatActor
    static func makeSession(
        configuration: AgentConfiguration,
        sessionRunner: AgentCoreSessionRunner
    ) async -> ZenCODEHeadlessSession {
        let host = HeadlessInteractionHost()
        let chatSession = ChatSessionController(
            sessionID: TerminalChat.newTerminalSessionID(),
            managementRuntime: sessionRunner,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: sessionRunner.swiftFeatureRuntime
            ),
            workingDirectory: configuration.workingDirectory,
            presenter: HeadlessSilentPresenter(),
            host: host,
            authorizer: ChatToolConsentAuthorizer(host: host),
            retainsTranscript: false,
            retainsFileArtifactHistory: false
        )
        await chatSession.applyInitialAgentSelectionIfNeeded()
        let sessionConfiguration = await chatSession.currentSessionConfiguration(
            discoverExternalTools: false,
            responseLanguageSection: nil
        )
        return ZenCODEHeadlessSession(
            configuration: sessionConfiguration,
            promptSkills: chatSession.selectedPromptSkills()
        )
    }

    /// Lifecycle seam for focused tests. Output mode still comes only from the
    /// same configuration used by production; sinks merely observe framed JSONL
    /// records or the legacy final text. A nil sink writes to standard output.
    @TerminalChatActor
    static func runTurn(
        configuration: AgentConfiguration,
        prompt: String,
        sessionRunner: any ZenCODEHeadlessSessionRunning,
        sessionConfiguration: AgentCoreSessionConfiguration,
        promptSkills: [PromptSkill] = [],
        consentAuthorizer: ChatToolConsentAuthorizer? = nil,
        jsonlSink: ZenCODEHeadlessJSONLWriter.Sink? = nil,
        textSink: TextSink? = nil
    ) async throws {
        let textSink = textSink ?? { text in
            AgentOutput.standardOutput.writeString(text)
        }
        let writer = configuration.jsonl
            ? ZenCODEHeadlessJSONLWriter(sink: jsonlSink)
            : nil
        if let writer {
            await writer.start()
        }

        do {
            try await sessionRunner.headlessCreateSession(
                configuration: sessionConfiguration,
                promptSkills: promptSkills
            )
        } catch {
            await sessionRunner.headlessShutdown()
            if let writer {
                await writer.write(error: error)
                await writer.close()
            }
            throw error
        }

        let host = HeadlessInteractionHost()
        let presenter: any ChatSessionPresenter = writer.map(HeadlessJSONLPresenter.init)
            ?? HeadlessSilentPresenter()
        let chatSession = ChatSessionController(
            sessionID: sessionConfiguration.sessionID,
            runtime: sessionRunner,
            // The turn runs on the composed configuration; this controller
            // composes nothing, so it needs no feature runtime.
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: nil
            ),
            workingDirectory: configuration.workingDirectory,
            presenter: presenter,
            host: host,
            authorizer: consentAuthorizer ?? ChatToolConsentAuthorizer(host: host),
            retainsTranscript: false,
            retainsFileArtifactHistory: false
        )
        let response: DirectAgentResponse
        do {
            do {
                response = try await chatSession.runTurn(
                    ChatTurnRequest(
                        prompt: prompt,
                        attachments: [],
                        purpose: .normal,
                        sessionConfiguration: sessionConfiguration
                    )
                ).response
            } catch let failure as ChatTurnFailure {
                // The JSONL error record classifies the runtime error itself.
                throw failure.underlying
            }
            guard configuration.jsonl
                ? !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : !response.text.isEmpty else {
                throw ZenCODEHeadlessRunnerError.noResponse
            }
        } catch {
            // A created session is closed exactly once on turn failure. Cleanup
            // errors cannot replace or duplicate the already selected terminal
            // turn error.
            try? await sessionRunner.headlessCloseSession(id: sessionConfiguration.sessionID)
            await sessionRunner.headlessShutdown()
            if let writer {
                await writer.write(error: error)
                await writer.close()
            }
            throw error
        }

        if let writer {
            do {
                // JSONL teardown precedes every success record. If it fails, do
                // not attempt it a second time and do not emit success.
                try await sessionRunner.headlessCloseSession(id: sessionConfiguration.sessionID)
            } catch {
                await sessionRunner.headlessShutdown()
                await writer.write(error: ZenCODEHeadlessTeardownError())
                await writer.close()
                throw error
            }
            await sessionRunner.headlessShutdown()
            await writer.write(result: response)
            await writer.close()
        } else {
            // Preserve the legacy ordering: final text is written before the
            // fallible close, so a teardown failure cannot suppress text that
            // was already successfully generated. The close error still
            // propagates and therefore retains the legacy failing exit status.
            var text = response.text
            if !text.hasSuffix("\n") {
                text.append("\n")
            }
            textSink(text)
            do {
                try await sessionRunner.headlessCloseSession(id: sessionConfiguration.sessionID)
            } catch {
                // Match the pre-JSONL lifecycle wrapper: persistence failures are
                // diagnostic-only after a completed textual turn and must not
                // change its output or exit status.
                ZenLogger.error(
                    .viewModelRuntime,
                    "headless runner could not flush task graph: \(error.localizedDescription)"
                )
            }
            await sessionRunner.headlessShutdown()
        }
    }
}

public enum ZenCODEHeadlessRunnerError: LocalizedError {
    case noPrompt
    case noResponse

    public var errorDescription: String? {
        switch self {
        case .noPrompt:
            return "No prompt provided. Pass text after -p/--prompt."
        case .noResponse:
            return "The backend produced no assistant text."
        }
    }
}

/// Marker used only for public classification. The underlying teardown error is
/// deliberately not retained or serialized.
struct ZenCODEHeadlessTeardownError: Error {}

/// Headless JSONL output of a chat turn: only the protocol-approved records
/// (tool lifecycle and the turn outcome that classifies a failure). No other
/// event reaches the public wire.
struct HeadlessJSONLPresenter: ChatSessionPresenter {
    let writer: ZenCODEHeadlessJSONLWriter

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await writer.write(event: .toolCallStarted(toolCall))
    }

    func presentToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        await writer.write(event: .toolCallCompleted(toolCall, result))
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await writer.write(event: .turnEnded(outcome))
    }
}

/// Plain-text headless output: only the final text, written by the runner.
struct HeadlessSilentPresenter: ChatSessionPresenter {}

/// The headless runner has no operator: it offers no interaction at all, so
/// gated tools are refused instead of prompting.
struct HeadlessInteractionHost: ChatInteractionHost {
    var capabilities: ChatChannelCapabilities { [] }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }
}
