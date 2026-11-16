//
//  TaskRecord.swift
//  ZenCODE
//
//  A persisted task of a session task graph: its definition, status,
//  attempts, results and evidence, plus the complexity rubric and delegation
//  policies shown to agents.
//

import Foundation
import ToolCore

public struct TaskRecord: Codable, Equatable, Sendable, Identifiable {
    /// The valid range for task complexity; values outside it are clamped.
    public static let complexityRange: ClosedRange<Int> = 1...10

    /// Clamps a raw complexity value into `complexityRange`.
    public static func clampedComplexity(_ value: Int) -> Int {
        min(max(value, complexityRange.lowerBound), complexityRange.upperBound)
    }

    /// The canonical complexity rubric shared by tool schemas and system prompts.
    public static let complexityRubric = "1-3 = simple lookup, single-file edit, or mechanical change; "
        + "4-6 = standard multi-file implementation or focused analysis; "
        + "7-10 = complex architecture, cross-system integration, or deep reasoning"

    /// The canonical policy for selecting a delegated agent and one of its
    /// authorized model bindings, when configured, from task complexity.
    public static let agentSelectionPolicy =
        "Determine the task type and required tools before comparing capability. "
        + "Exclude profiles whose stated role or constraints are incompatible, and do not "
        + "delegate when the effective tool grant cannot perform the work. For a compatible "
        + "profile with configured bindings, choose only one of its authorized model bindings: "
        + "use the lowest-capability binding that is greater than or equal to task complexity. If none meets the "
        + "complexity, use that profile's highest-capability binding and explicitly report the "
        + "capability gap. For a profile without bindings, omit model in agent.create to inherit "
        + "the main session model and provider; do not invent a binding or capability rating. "
        + "Never select a profile or model binding by capability alone."

    /// The canonical policy that treats configured model bindings as a cost
    /// signal when deciding between direct execution and delegation. It applies
    /// to every direct-versus-delegate decision, inside or outside a task graph.
    public static let delegationCostPolicy =
        "Configured bindings are also a cost ladder: a lower capability is a cheaper model, "
        + "and direct work spends the main session model, normally the top of that ladder. "
        + "When a role/tool-compatible profile exposes a binding whose capability is lower than "
        + "the main session model and still meets the task complexity, delegate the task to the "
        + "cheapest sufficient binding even when direct execution would be faster; keep "
        + "coordination (including live steering through the shared chat), a precise brief "
        + "(files, constraints, acceptance criteria), and validation of the result for yourself. Only complexity-1 work whose context is already "
        + "in hand stays direct. When no compatible profile has bindings, delegation saves nothing: "
        + "work directly unless real parallelism, separate ownership, or a different tool grant "
        + "justifies a sub-agent."

    /// The canonical coordinator policy for the shared chat (`agent.message`).
    /// The chat is the standard coordination channel; the only technical limit
    /// is that a closed attempt cannot resume implementation.
    public static let collaborationPolicy =
        "Collaboration policy: the shared chat (agent.message) is the standard channel to "
        + "coordinate delegated agents; prefer it to guessing or waiting silently. Answer a "
        + "sub-agent's question immediately and precisely, then call agent.wait again; it "
        + "returns early when chat messages are waiting for you. Steer agents in chat while "
        + "their work is in progress instead of waiting for it to finish, and forward to "
        + "parallel agents the information that concerns them. Sub-agents stop and wait for "
        + "your reply when they hit an ambiguity or a decision outside their brief, and they "
        + "do not send progress reports. Use the chat to clarify, steer, and query agents, "
        + "including standby ones, for example to learn what an agent did before deciding on a "
        + "retry; a closed attempt cannot resume implementation."

    public let id: String
    public var title: String
    public var details: String?
    public var order: Int
    public var status: TaskStatus
    public var priority: TaskPriority
    public var dependsOn: [String]
    public var execution: TaskExecutionSpec
    public var acceptanceCriteria: [String]
    public var activeAttemptID: String?
    public var attempts: [TaskAttempt]
    public var result: TaskResult?
    public var statusReason: String?
    public var revision: Int
    public var complexity: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        details: String? = nil,
        order: Int,
        status: TaskStatus = .pending,
        priority: TaskPriority = .normal,
        dependsOn: [String] = [],
        execution: TaskExecutionSpec = TaskExecutionSpec(),
        acceptanceCriteria: [String] = [],
        activeAttemptID: String? = nil,
        attempts: [TaskAttempt] = [],
        result: TaskResult? = nil,
        statusReason: String? = nil,
        revision: Int = 1,
        complexity: Int = 5,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details?.nilIfBlank
        self.order = order
        self.status = status
        self.priority = priority
        self.dependsOn = dependsOn
        self.execution = execution
        self.acceptanceCriteria = acceptanceCriteria.compactMap(\.nilIfBlank)
        self.activeAttemptID = activeAttemptID?.nilIfBlank
        self.attempts = attempts
        self.result = result
        self.statusReason = statusReason?.nilIfBlank
        self.revision = revision
        self.complexity = Self.clampedComplexity(complexity)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case details
        case order
        case status
        case priority
        case dependsOn
        case execution
        case acceptanceCriteria
        case activeAttemptID
        case attempts
        case result
        case statusReason
        case revision
        case complexity
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.details = try container.decodeIfPresent(String.self, forKey: .details)?.nilIfBlank
        self.order = try container.decode(Int.self, forKey: .order)
        self.status = try container.decode(TaskStatus.self, forKey: .status)
        self.priority = try container.decode(TaskPriority.self, forKey: .priority)
        self.dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        self.execution = try container.decodeIfPresent(TaskExecutionSpec.self, forKey: .execution) ?? TaskExecutionSpec()
        self.acceptanceCriteria = try container.decodeIfPresent([String].self, forKey: .acceptanceCriteria) ?? []
        self.activeAttemptID = try container.decodeIfPresent(String.self, forKey: .activeAttemptID)?.nilIfBlank
        self.attempts = try container.decodeIfPresent([TaskAttempt].self, forKey: .attempts) ?? []
        self.result = try container.decodeIfPresent(TaskResult.self, forKey: .result)
        self.statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason)?.nilIfBlank
        self.revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        self.complexity = try container.decodeIfPresent(Int.self, forKey: .complexity).map { min(max($0, 1), 10) } ?? 5
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public var activeAttempt: TaskAttempt? {
        guard let activeAttemptID else { return nil }
        return attempts.first { $0.id == activeAttemptID }
    }

    public var assigneeAgentID: String? { activeAttempt?.agentID }
}
