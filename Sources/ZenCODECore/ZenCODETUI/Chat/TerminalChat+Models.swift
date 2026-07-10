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

public enum TerminalSessionPlanPointStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case blocked
}

public struct TerminalSessionPlanPoint: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public var status: TerminalSessionPlanPointStatus

    public init(
        id: String,
        text: String,
        status: TerminalSessionPlanPointStatus = .pending
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
    }
}

public struct TerminalSessionPlan: Codable, Equatable, Sendable {
    public let originalGoal: String
    public let consolidatedText: String
    public let createdAt: Date
    public var isApproved: Bool
    public var points: [TerminalSessionPlanPoint]

    public init(
        originalGoal: String,
        consolidatedText: String,
        createdAt: Date = Date(),
        isApproved: Bool = false,
        points: [TerminalSessionPlanPoint] = []
    ) {
        self.originalGoal = originalGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.consolidatedText = consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.isApproved = isApproved
        self.points = points
    }

    public var isCompleted: Bool {
        !points.isEmpty && points.allSatisfy { $0.status == .completed }
    }

    private enum CodingKeys: String, CodingKey {
        case originalGoal
        case consolidatedText
        case createdAt
        case isApproved
        case points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalGoal = try container.decode(String.self, forKey: .originalGoal)
        consolidatedText = try container.decode(String.self, forKey: .consolidatedText)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isApproved = try container.decode(Bool.self, forKey: .isApproved)
        points = try container.decodeIfPresent(
            [TerminalSessionPlanPoint].self,
            forKey: .points
        ) ?? []
    }
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
    case telegramMessage(TerminalTelegramIncomingMessage)
    case voicePromptProgress(TerminalVoicePromptProgress)
    case voicePromptCompleted(TerminalVoicePromptResult)
}
