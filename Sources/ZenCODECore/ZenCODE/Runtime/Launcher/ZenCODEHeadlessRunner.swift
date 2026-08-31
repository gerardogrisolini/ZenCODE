//
//  ZenCODEHeadlessRunner.swift
//  ZenCODE
//

import Foundation

/// Minimal lifecycle surface used by the headless turn executor. Production
/// delegates to `AgentCoreSessionRunner`; tests can supply a controlled actor
/// without replacing the CLI or weakening the real session composition.
protocol ZenCODEHeadlessSessionRunning: Actor {
    func headlessCreateSession(configuration: AgentCoreSessionConfiguration) async throws
    func headlessSendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse
    func headlessCloseSession(id: String) async throws
    func headlessShutdown() async
}

extension AgentCoreSessionRunner: ZenCODEHeadlessSessionRunning {
    func headlessCreateSession(configuration: AgentCoreSessionConfiguration) async throws {
        try await createSession(configuration: configuration)
    }

    func headlessSendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        try await sendPrompt(
            configuration: configuration,
            prompt: prompt,
            attachments: [],
            onEvent: onEvent
        )
    }

    func headlessCloseSession(id: String) async throws {
        try await closeSessionThrowing(id: id)
    }

    func headlessShutdown() async {
        await shutdown()
    }
}

/// Executes one non-interactive text turn without starting the terminal UI.
public enum ZenCODEHeadlessRunner {
    typealias TextSink = @Sendable (String) -> Void

    /// Resolves an inline prompt and appends piped stdin as additional context.
    public static func prompt(
        inlinePrompt: String?,
        stdin: FileHandle = .standardInput,
        stdinIsTerminal: Bool
    ) throws -> String {
        guard let inlinePrompt else {
            throw ZenCODEHeadlessRunnerError.noPrompt
        }
        let stdinText = stdinIsTerminal
            ? ""
            : String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = inlinePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @TerminalChatActor
    public static func run(
        configuration: AgentConfiguration,
        prompt: String,
        permissionAuthorizer: LocalExecPermissionAuthorizer,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async throws {
        let sessionRunner = AgentCoreSessionRunner(
            // This path never opens or reads a terminal consent dialog. It still
            // honors persisted approvals and tools which do not require consent.
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorizeNonInteractively(request)
            },
            backendFactory: backendFactory
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: sessionRunner
        )
        let sessionConfiguration = await terminal.currentSessionConfiguration(
            discoverExternalTools: false
        )
        try await runTurn(
            configuration: configuration,
            prompt: prompt,
            sessionRunner: sessionRunner,
            sessionConfiguration: sessionConfiguration
        )
    }

    /// Lifecycle seam for focused tests. Output mode still comes only from the
    /// same configuration used by production; sinks merely observe framed JSONL
    /// records or the legacy final text.
    @TerminalChatActor
    static func runTurn(
        configuration: AgentConfiguration,
        prompt: String,
        sessionRunner: any ZenCODEHeadlessSessionRunning,
        sessionConfiguration: AgentCoreSessionConfiguration,
        jsonlSink: ZenCODEHeadlessJSONLWriter.Sink? = nil,
        textSink: @escaping TextSink = { text in
            AgentOutput.standardOutput.writeString(text)
        }
    ) async throws {
        let writer = configuration.jsonl
            ? ZenCODEHeadlessJSONLWriter(sink: jsonlSink)
            : nil
        if let writer {
            await writer.start()
        }

        do {
            try await sessionRunner.headlessCreateSession(configuration: sessionConfiguration)
        } catch {
            await sessionRunner.headlessShutdown()
            if let writer {
                await writer.write(error: error)
                await writer.close()
            }
            throw error
        }

        let response: DirectAgentResponse
        do {
            response = try await sessionRunner.headlessSendPrompt(
                configuration: sessionConfiguration,
                prompt: prompt
            ) { event in
                if let writer {
                    await writer.write(event: event)
                }
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
