//
//  TerminalChat+Models.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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
/// setup rather than restoring their previous values. Prompt history travels
/// here only; it is never part of a persisted conversation snapshot.
public struct TerminalChatResumeSnapshot: Sendable {
    public let sessionID: String
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let transcriptHistory: [AgentRuntimeMessage]
    public let activePlan: TerminalSessionPlan?
    public let checkpointTree: SessionCheckpointTree?
    public let savedSessionName: String?
    /// Prompt submissions for this process, separate from saved conversation data.
    public let commandHistory: [String]

    public init(
        sessionID: String,
        cacheKey: String?,
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage],
        activePlan: TerminalSessionPlan?,
        checkpointTree: SessionCheckpointTree?,
        savedSessionName: String?,
        commandHistory: [String] = []
    ) {
        self.sessionID = sessionID
        self.cacheKey = cacheKey
        self.history = history
        self.transcriptHistory = transcriptHistory
        self.activePlan = activePlan
        self.checkpointTree = checkpointTree
        self.savedSessionName = savedSessionName
        self.commandHistory = commandHistory
    }
}

public enum TerminalChatRunOutcome: Sendable {
    case exited
    case setupRequested(TerminalChatResumeSnapshot)
}

/// Compatibility name used by the terminal frontend for ``ChatTurnPurpose``.
typealias TerminalPromptPurpose = ChatTurnPurpose

/// Compatibility name used by the terminal frontend. The implementation lives
/// in the shared coordinator kernel and remains deliberately non-Codable.
typealias TerminalPlanBrainstormingState = PlanningCommandRuntimeState

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
    let finalAssistantContent: String
}

struct TerminalChatGenerationRunError: Error, Sendable {
    let underlying: Error
    let fileChangeSummary: TurnFileChangeSummary?
}

enum TerminalPromptOrigin: Sendable, Equatable {
    case local
    case telegram(chatID: Int64)
    case telegramRoute(TerminalTelegramRouteKey)
    case telegramLease(TerminalTelegramRouteLease)

    var telegramChatID: Int64? {
        switch self {
        case .local:
            return nil
        case let .telegram(chatID):
            return chatID
        case let .telegramRoute(route):
            return route.chatID
        case let .telegramLease(lease):
            return lease.key.chatID
        }
    }

    var telegramRoute: TerminalTelegramRouteKey? {
        switch self {
        case let .telegramRoute(route): return route
        case let .telegramLease(lease): return lease.key
        case .local, .telegram: return nil
        }
    }

    var telegramLease: TerminalTelegramRouteLease? {
        guard case let .telegramLease(lease) = self else { return nil }
        return lease
    }
}

/// Compatibility names used by the terminal frontend for the queue types of the
/// Chat layer. The origin stays a terminal type (``TerminalPromptOrigin``) and
/// is supplied here, so the Chat layer never depends on it.
typealias TerminalQueuedPrompt = ChatQueuedPrompt<TerminalPromptOrigin>
typealias TerminalQueuedPromptMode = ChatQueuedPromptMode

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
    case telegramRouteInvalidated(TerminalTelegramRouteLease)
    /// Telegram polling entered or left a persistent failure.
    case telegramPollHealthChanged(TerminalTelegramPollHealthNotice)
    case voicePromptCompleted(TerminalVoicePromptResult)
    /// A dictated utterance. The runtime loop decides whether it answers a
    /// spoken live-chat question, sends a "message to …" phrase, or becomes
    /// an ordinary prompt.
    case voiceUtterance(String)
    /// The voice controller started (`true`) or stopped (`false`) reading
    /// aloud; the end of a spoken question starts waiting for its answer.
    case voiceSpeakingChanged(Bool)
    /// A comment the root agent wrote before a tool call while voice mode is
    /// on. The runtime loop reads it aloud only while the turn runs, nothing
    /// else is being read and no live-chat question is in progress; otherwise
    /// it is dropped and stays on screen only.
    case voiceCommentary(String)
    /// A spoken live-chat question waited too long for its answer. The token
    /// identifies the question so a late timer cannot close a newer one.
    case voiceDialogueTimedOut(UUID)
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
             .telegramRouteInvalidated,
             .telegramPollHealthChanged,
             .voicePromptCompleted,
             .voiceUtterance,
             .voiceSpeakingChanged,
             .voiceCommentary,
             .voiceDialogueTimedOut,
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
