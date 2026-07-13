//
//  TerminalChat+Models.swift
//  ZenCODE
//

import Foundation

enum TerminalSubmittedLineAction {
    case continueChat
    case exitChat
    case runPrompt(String)
    case runHiddenPrompt(String, purpose: TerminalPromptPurpose)
    case prefillPrompt(String)
}

enum TerminalPromptPurpose: Sendable, Equatable {
    case normal
    case plan(originalGoal: String)
    case review
}

struct TerminalPromptAttempt: Sendable {
    let prompt: String
    let attachments: [AgentRuntimeAttachment]
    let origin: TerminalPromptOrigin
    let locksResponseLanguage: Bool
    let purpose: TerminalPromptPurpose
}

struct TerminalChatGenerationFailure: Sendable {
    let message: String
    let isCancellation: Bool
    let origin: TerminalPromptOrigin
    let fileChangeSummary: TurnFileChangeSummary?

    init(
        message: String,
        isCancellation: Bool,
        origin: TerminalPromptOrigin,
        fileChangeSummary: TurnFileChangeSummary?
    ) {
        self.message = message
        self.isCancellation = isCancellation
        self.origin = origin
        self.fileChangeSummary = fileChangeSummary
    }

    init(
        error: Error,
        origin: TerminalPromptOrigin
    ) {
        let runError = error as? TerminalChatGenerationRunError
        let underlying = runError?.underlying ?? error
        let isCancellation = underlying is CancellationError
        self.init(
            message: underlying.localizedDescription,
            isCancellation: isCancellation,
            origin: origin,
            fileChangeSummary: runError?.fileChangeSummary
        )
    }
}

struct TerminalChatGenerationSuccess: Sendable {
    let response: DirectAgentResponse
    let origin: TerminalPromptOrigin
    let fileChangeSummary: TurnFileChangeSummary?
    let automaticallyCompletedPlan: TerminalSessionPlan?
}

struct TerminalChatGenerationRunError: Error, Sendable {
    let underlying: Error
    let fileChangeSummary: TurnFileChangeSummary?
}

enum TerminalPromptOrigin: Sendable, Equatable {
    case local
    case telegram(chatID: Int64)

    var telegramChatID: Int64? {
        switch self {
        case .local:
            return nil
        case let .telegram(chatID):
            return chatID
        }
    }
}

struct TerminalQueuedPrompt: Sendable, Equatable {
    let text: String
    let origin: TerminalPromptOrigin
    let mode: TerminalQueuedPromptMode

    init(
        text: String,
        origin: TerminalPromptOrigin,
        mode: TerminalQueuedPromptMode = .submittedLine
    ) {
        self.text = text
        self.origin = origin
        self.mode = mode
    }
}

enum TerminalQueuedPromptMode: Sendable, Equatable {
    case submittedLine
    case directPrompt
}

struct TerminalVoicePromptResult: Sendable {
    let origin: TerminalPromptOrigin
    let outcome: Outcome

    enum Outcome: Sendable {
        case success(String)
        case failure(String)
    }
}

struct TerminalVoicePromptProgress: Sendable {
    let origin: TerminalPromptOrigin
    let message: String

    init(origin: TerminalPromptOrigin, message: String) {
        self.origin = origin
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TerminalChatGenerationResult: Sendable {
    case success(TerminalChatGenerationSuccess)
    case failure(TerminalChatGenerationFailure)
}

enum TerminalChatRuntimeEvent: Sendable {
    case input(TerminalPromptInputEvent)
    case generationCompleted(TerminalChatGenerationResult)
    case startNextQueuedPrompt
    case telegramMessage(TerminalTelegramIncomingMessage)
    case voicePromptProgress(TerminalVoicePromptProgress)
    case voicePromptCompleted(TerminalVoicePromptResult)
}
