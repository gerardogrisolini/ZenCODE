//
//  TerminalSessionPlan.swift
//  ZenCODE
//

import Foundation

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
