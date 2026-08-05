//
//  TerminalChat+Models.swift
//  ZenCODE
//

import Foundation

enum TerminalSubmittedLineAction {
    case continueChat
    case exitChat
    case requestSetup
    case runPrompt(String)
    case runHiddenPrompt(String, purpose: TerminalPromptPurpose)
    case prefillPrompt(String)
}

/// In-memory state carried across the coarse runtime restart requested by
/// `/setup`. Configuration-derived state is intentionally absent: the relaunched
/// chat must use the providers, model, agent, tools, and skills just written by
/// setup rather than restoring their previous values.
public struct TerminalChatResumeSnapshot: Sendable {
    public let sessionID: String
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let transcriptHistory: [AgentRuntimeMessage]
    public let activePlan: TerminalSessionPlan?
    public let checkpointTree: SessionCheckpointTree?
    public let savedSessionName: String?

    public init(
        sessionID: String,
        cacheKey: String?,
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage],
        activePlan: TerminalSessionPlan?,
        checkpointTree: SessionCheckpointTree?,
        savedSessionName: String?
    ) {
        self.sessionID = sessionID
        self.cacheKey = cacheKey
        self.history = history
        self.transcriptHistory = transcriptHistory
        self.activePlan = activePlan
        self.checkpointTree = checkpointTree
        self.savedSessionName = savedSessionName
    }
}

public enum TerminalChatRunOutcome: Sendable {
    case exited
    case setupRequested(TerminalChatResumeSnapshot)
}

enum TerminalPromptPurpose: Sendable, Equatable {
    case normal
    case agentsMarkdown
    case plan(originalGoal: String)
    case workflow(originalGoal: String)
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
    /// Post-condition of an `/agents-md` turn; `nil` for every other purpose.
    let agentsMarkdownOutcome: AgentsMarkdownWriteOutcome?
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

enum TerminalChatGenerationResult: Sendable {
    case success(TerminalChatGenerationSuccess)
    case failure(TerminalChatGenerationFailure)
}

enum TerminalChatRuntimeEvent: Sendable {
    case input(TerminalPromptInputEvent)
    case generationCompleted(TerminalChatGenerationResult)
    case startNextQueuedPrompt
    case telegramMessage(TerminalTelegramIncomingMessage)
    case voicePromptCompleted(TerminalVoicePromptResult)
}
