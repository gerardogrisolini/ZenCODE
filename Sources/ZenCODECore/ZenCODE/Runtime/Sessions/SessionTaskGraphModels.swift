//
//  SessionTaskGraphModels.swift
//  ZenCODE
//

import Foundation

public enum TaskGraphSource: Codable, Equatable, Sendable {
    case manual
    case plan(planID: String)
    case workflow

    private enum CodingKeys: String, CodingKey {
        case kind
        case planID
    }

    private enum Kind: String, Codable {
        case manual
        case plan
        case workflow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual:
            self = .manual
        case .plan:
            self = .plan(planID: try container.decode(String.self, forKey: .planID))
        case .workflow:
            self = .workflow
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case let .plan(planID):
            try container.encode(Kind.plan, forKey: .kind)
            try container.encode(planID, forKey: .planID)
        case .workflow:
            try container.encode(Kind.workflow, forKey: .kind)
        }
    }

    public var planID: String? {
        guard case let .plan(planID) = self else { return nil }
        return planID
    }

    /// Workflow graphs are execution-owned by delegated sub-agents. The
    /// coordinator still owns graph management, but never starts a task attempt.
    public var requiresSubAgentExecution: Bool {
        self == .workflow
    }
}

public enum TaskGraphState: String, Codable, Equatable, Sendable {
    case draft
    case active
    case completed
    case cancelled
    case archived

    public var permitsExecution: Bool { self == .active }

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .archived: true
        case .draft, .active: false
        }
    }
}

public enum TaskStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case awaitingValidation = "awaiting_validation"
    case completed
    case blocked
    case failed
    case cancelled

    public init(normalizing rawValue: String?) {
        switch Self.normalized(rawValue) {
        case "in_progress", "inprogress", "active", "running": self = .inProgress
        case "awaiting_validation", "awaitingvalidation", "validation", "needs_validation": self = .awaitingValidation
        case "completed", "complete", "done", "success", "succeeded": self = .completed
        case "blocked", "blocker": self = .blocked
        case "failed", "failure", "error": self = .failed
        case "cancelled", "canceled", "cancel": self = .cancelled
        default: self = .pending
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .pending, .inProgress, .awaitingValidation, .blocked: false
        }
    }

    public var preventsDependentExecution: Bool {
        self == .failed || self == .cancelled
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

public enum TaskPriority: String, Codable, Equatable, Sendable, CaseIterable {
    case low
    case normal
    case high

    public init(normalizing rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": self = .low
        case "high", "urgent", "critical": self = .high
        default: self = .normal
        }
    }

    public var sortRank: Int {
        switch self {
        case .high: 2
        case .normal: 1
        case .low: 0
        }
    }
}

public enum TaskExecutorKind: String, Codable, Equatable, Sendable {
    case coordinator
    case subAgent = "sub_agent"
}

public struct TaskExecutionSpec: Codable, Equatable, Sendable {
    public var executor: TaskExecutorKind
    public var profile: String?
    public var role: String?
    public var toolNames: [String]
    public var fileScopes: [String]

    public init(
        executor: TaskExecutorKind = .coordinator,
        profile: String? = nil,
        role: String? = nil,
        toolNames: [String] = [],
        fileScopes: [String] = []
    ) {
        self.executor = executor
        self.profile = profile?.nilIfBlank
        self.role = role?.nilIfBlank
        self.toolNames = toolNames.compactMap(\.nilIfBlank)
        self.fileScopes = fileScopes.compactMap(\.nilIfBlank)
    }
}

public enum TaskAttemptStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case interrupted

    public var isActive: Bool { self == .queued || self == .running }
}

public struct TaskAttempt: Codable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int
    public let agentID: String?
    public let executor: TaskExecutorKind
    public var status: TaskAttemptStatus
    public let startedAt: Date
    public var finishedAt: Date?
    public var output: String?
    public var error: String?

    public init(
        id: String,
        ordinal: Int,
        agentID: String?,
        executor: TaskExecutorKind,
        status: TaskAttemptStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        output: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.agentID = agentID?.nilIfBlank
        self.executor = executor
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output?.nilIfBlank
        self.error = error?.nilIfBlank
    }
}

public struct TaskEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var kind: String
    public var summary: String
    public var location: String?
    public let createdAt: Date

    public init(
        id: String = "evidence_\(UUID().uuidString.lowercased())",
        kind: String,
        summary: String,
        location: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location?.nilIfBlank
        self.createdAt = createdAt
    }
}

public struct TaskResult: Codable, Equatable, Sendable {
    public var summary: String?
    public var output: String?
    public var error: String?
    public var evidence: [TaskEvidence]
    public var finishedAt: Date?
    public var validatedAt: Date?

    public init(
        summary: String? = nil,
        output: String? = nil,
        error: String? = nil,
        evidence: [TaskEvidence] = [],
        finishedAt: Date? = nil,
        validatedAt: Date? = nil
    ) {
        self.summary = summary?.nilIfBlank
        self.output = output?.nilIfBlank
        self.error = error?.nilIfBlank
        self.evidence = evidence
        self.finishedAt = finishedAt
        self.validatedAt = validatedAt
    }
}

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
    /// authorized model bindings from task complexity.
    public static let agentSelectionPolicy =
        "Determine the task type and required tools before comparing capability. "
        + "Exclude profiles whose stated role or constraints are incompatible, and do not "
        + "delegate when the effective tool grant cannot perform the work. For a compatible "
        + "profile, choose only one of its authorized model bindings: use the lowest-capability "
        + "binding that is greater than or equal to task complexity. If none meets the "
        + "complexity, use that profile's highest-capability binding and explicitly report the "
        + "capability gap. Never select a profile or model binding by capability alone."

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

public struct TaskGraphSnapshot: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let source: TaskGraphSource
    public var state: TaskGraphState
    public var revision: Int
    public var tasks: [TaskRecord]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String,
        source: TaskGraphSource,
        state: TaskGraphState,
        revision: Int = 1,
        tasks: [TaskRecord] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.state = state
        self.revision = revision
        self.tasks = tasks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TaskRecordView: Equatable, Sendable {
    public let graphID: String
    public let graphRevision: Int
    public let graphState: TaskGraphState
    public let task: TaskRecord
    public let isRunnable: Bool
    public let blockedBy: [String]
    public let blockedReason: String?
    public let dependents: [String]

    public init(
        graphID: String,
        graphRevision: Int,
        graphState: TaskGraphState,
        task: TaskRecord,
        isRunnable: Bool,
        blockedBy: [String],
        blockedReason: String?,
        dependents: [String]
    ) {
        self.graphID = graphID
        self.graphRevision = graphRevision
        self.graphState = graphState
        self.task = task
        self.isRunnable = isRunnable
        self.blockedBy = blockedBy
        self.blockedReason = blockedReason
        self.dependents = dependents
    }
}

public struct TaskDefinition: Equatable, Sendable {
    public var id: String?
    public var title: String
    public var details: String?
    public var order: Int?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var dependsOn: [String]
    public var execution: TaskExecutionSpec
    public var acceptanceCriteria: [String]
    public var output: String?
    public var complexity: Int?

    public init(
        id: String? = nil,
        title: String,
        details: String? = nil,
        order: Int? = nil,
        status: TaskStatus = .pending,
        priority: TaskPriority = .normal,
        dependsOn: [String] = [],
        execution: TaskExecutionSpec = TaskExecutionSpec(),
        acceptanceCriteria: [String] = [],
        output: String? = nil,
        complexity: Int? = nil
    ) {
        self.id = id?.nilIfBlank
        self.title = title
        self.details = details
        self.order = order
        self.status = status
        self.priority = priority
        self.dependsOn = dependsOn
        self.execution = execution
        self.acceptanceCriteria = acceptanceCriteria
        self.output = output
        self.complexity = complexity.map(TaskRecord.clampedComplexity)
    }
}

public struct TaskUpdate: Equatable, Sendable {
    public var title: String?
    public var details: String?
    public var clearsDetails: Bool
    public var priority: TaskPriority?
    public var dependsOn: [String]?
    public var status: TaskStatus?
    public var statusReason: String?
    public var output: String?
    public var error: String?
    public var evidence: [TaskEvidence]
    public var expectedRevision: Int?
    public var complexity: Int?

    public init(
        title: String? = nil,
        details: String? = nil,
        clearsDetails: Bool = false,
        priority: TaskPriority? = nil,
        dependsOn: [String]? = nil,
        status: TaskStatus? = nil,
        statusReason: String? = nil,
        output: String? = nil,
        error: String? = nil,
        evidence: [TaskEvidence] = [],
        expectedRevision: Int? = nil,
        complexity: Int? = nil
    ) {
        self.title = title
        self.details = details
        self.clearsDetails = clearsDetails
        self.priority = priority
        self.dependsOn = dependsOn
        self.status = status
        self.statusReason = statusReason
        self.output = output
        self.error = error
        self.evidence = evidence
        self.expectedRevision = expectedRevision
        self.complexity = complexity.map(TaskRecord.clampedComplexity)
    }
}

public struct TaskClaim: Equatable, Sendable {
    public let taskID: String
    public let agentID: String?
    public let executor: TaskExecutorKind

    public init(taskID: String, agentID: String? = nil, executor: TaskExecutorKind = .subAgent) {
        self.taskID = taskID
        self.agentID = agentID?.nilIfBlank
        self.executor = executor
    }
}

public struct TaskClaimReceipt: Equatable, Sendable {
    public let graphID: String
    public let taskID: String
    public let attemptID: String
    public let ordinal: Int
    public let agentID: String?
}

public struct TaskCancellation: Equatable, Sendable {
    public let graphID: String
    public let taskID: String
    public let attemptID: String?
    public let agentID: String?
}

public struct TaskExecutionScope: Codable, Equatable, Sendable {
    public let rootSessionID: String
    public let graphID: String?
    public let taskID: String
    public let attemptID: String

    public init(
        rootSessionID: String,
        graphID: String? = nil,
        taskID: String,
        attemptID: String
    ) {
        self.rootSessionID = rootSessionID
        self.graphID = graphID?.nilIfBlank
        self.taskID = taskID
        self.attemptID = attemptID
    }
}

public struct SessionTaskGraphCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: String
    public var currentGraphID: String?
    public var graphs: [TaskGraphSnapshot]
    public var savedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: String,
        currentGraphID: String?,
        graphs: [TaskGraphSnapshot],
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.currentGraphID = currentGraphID
        self.graphs = graphs
        self.savedAt = savedAt
    }
}

public struct TaskGraphEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case restored
        case created
        case updated
        case activated
        case archived
        case cleared
    }

    public let sessionID: String
    public let graphID: String?
    public let revision: Int?
    public let kind: Kind
    public let emittedAt: Date
}
