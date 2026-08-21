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
    /// The originating room remains attached while the event waits in the
    /// terminal queue. A session command can rebind the live observation before
    /// an already-enqueued event is consumed.
    case sharedChatMessages(roomID: String, messages: [AgentSharedChat.Message])
    case sharedChatParticipantsChanged(roomID: String)
    /// An observation ended without the TUI cancelling it. Its UUID prevents a
    /// late termination from a retired stream rebinding the current one.
    case sharedChatObservationEnded(roomID: String, observationID: UUID)
    /// The status-bar resize transaction collapsed the expanded dock before
    /// repainting. The runtime loop owns the matching input/read-buffer state.
    case sharedChatReaderCollapsed(observationID: UUID?)
    /// The Core coordinator authorised exactly one synthetic coordinator turn.
    case sharedChatAutoTrigger(AgentSharedChatAutoTrigger)

    /// `nil` for ordinary terminal work. Shared-chat events must be compared
    /// against the currently observed room before rendering or starting work:
    /// cancellation of an old observation cannot retract events it already
    /// placed in the FIFO queue.
    var sharedChatRoomID: String? {
        switch self {
        case let .sharedChatMessages(roomID, _),
             let .sharedChatParticipantsChanged(roomID),
             let .sharedChatObservationEnded(roomID, _):
            roomID
        case let .sharedChatAutoTrigger(trigger):
            trigger.roomID
        case .input,
             .generationCompleted,
             .startNextQueuedPrompt,
             .telegramMessage,
             .voicePromptCompleted,
             .sharedChatReaderCollapsed:
            nil
        }
    }

    /// An event is consumable only while both the observation and the terminal
    /// session still name its room. This deliberately makes a queued event from
    /// an observer that has not yet been rebound stale after `/new` or
    /// `/resume`.
    func belongsToActiveSharedChatRoom(
        observedRoomID: String,
        sessionID: String
    ) -> Bool {
        sharedChatRoomID == observedRoomID && observedRoomID == sessionID
    }
}
