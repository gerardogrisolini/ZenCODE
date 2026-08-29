//
//  ZenCODEHeadlessRunner.swift
//  ZenCODE
//

import Foundation

/// Executes one non-interactive text turn without starting the terminal UI.
public enum ZenCODEHeadlessRunner {
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

        do {
            try await sessionRunner.createSession(configuration: sessionConfiguration)
            let response = try await sessionRunner.sendPrompt(
                configuration: sessionConfiguration,
                prompt: prompt,
                attachments: []
            ) { _ in
                // Events contain progress, thinking, and tool presentation;
                // headless stdout deliberately contains only final text.
            }
            guard !response.text.isEmpty else {
                throw ZenCODEHeadlessRunnerError.noResponse
            }
            AgentOutput.standardOutput.writeString(response.text)
            if !response.text.hasSuffix("\n") {
                AgentOutput.standardOutput.writeString("\n")
            }
            await sessionRunner.closeSession(id: sessionConfiguration.sessionID)
            await sessionRunner.shutdown()
        } catch {
            await sessionRunner.closeSession(id: sessionConfiguration.sessionID)
            await sessionRunner.shutdown()
            throw error
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
