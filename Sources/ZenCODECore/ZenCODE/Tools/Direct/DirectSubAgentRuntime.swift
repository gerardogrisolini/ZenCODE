//
//  DirectSubAgentRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public typealias DirectSubAgentBackendFactory = @Sendable () -> any AgentRuntimeBackend

public actor DirectSubAgentRuntime {
    public enum Status: String, Sendable {
        case queued
        case running
        case idle
        case failed
        case closed

        public var isPending: Bool {
            self == .queued || self == .running
        }
    }

    public enum IsolationMode: String, Sendable {
        case report
        case implementation

        public init(rawValue: String?) {
            switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "implementation", "edit", "coding":
                self = .implementation
            default:
                self = .report
            }
        }
    }

    public struct AgentRecord {
        public let id: String
        public let sessionID: String
        public let name: String
        public let role: String
        public let isolationMode: IsolationMode
        public let backend: any AgentRuntimeBackend
        public let createdAt: Date
        public var updatedAt: Date
        public var status: Status
        public var pendingPrompts: [String]
        public var latestOutput: String?
        public var latestError: String?
        public var modelID: String? = nil
        public var modelRuntime: String? = nil
        public var currentActivity: String? = nil
        public var currentToolName: String? = nil
        public var latestContentPreview: String? = nil
        public var latestEventAt: Date? = nil
        public var runTask: Task<Void, Never>?
    }

    public struct AgentWork {
        public let backend: any AgentRuntimeBackend
        public let sessionID: String
        public let prompt: String
    }

    public struct AgentSnapshot: Sendable {
        public let id: String
        public let name: String
        public let role: String
        public let isolationMode: IsolationMode
        public let status: Status
        public let pending: Bool
        public let modelID: String?
        public let modelRuntime: String?
        public let currentActivity: String?
        public let currentToolName: String?
        public let latestContentPreview: String?
        public let latestEventAt: Date?
        public let latestOutput: String?
        public let latestError: String?
        public let createdAt: Date
        public let updatedAt: Date

        public init(
            id: String,
            name: String,
            role: String,
            isolationMode: IsolationMode,
            status: Status,
            pending: Bool,
            modelID: String? = nil,
            modelRuntime: String? = nil,
            currentActivity: String? = nil,
            currentToolName: String? = nil,
            latestContentPreview: String? = nil,
            latestEventAt: Date? = nil,
            latestOutput: String?,
            latestError: String?,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.name = name
            self.role = role
            self.isolationMode = isolationMode
            self.status = status
            self.pending = pending
            self.modelID = modelID
            self.modelRuntime = modelRuntime
            self.currentActivity = currentActivity
            self.currentToolName = currentToolName
            self.latestContentPreview = latestContentPreview
            self.latestEventAt = latestEventAt
            self.latestOutput = latestOutput
            self.latestError = latestError
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct RequestedAgentPayload {
        public let name: String
        public let role: String
        public let prompt: String?
        public let isolationMode: IsolationMode
        public let allowedToolNames: Set<String>?
    }

    public let backendFactory: DirectSubAgentBackendFactory
    public var agents: [String: AgentRecord] = [:]

    public init(backendFactory: @escaping DirectSubAgentBackendFactory) {
        self.backendFactory = backendFactory
    }

    public func shutdown() async {
        let records = Array(agents.values)
        agents.removeAll()

        for record in records {
            record.runTask?.cancel()
        }
        for record in records {
            await record.backend.shutdown()
        }
    }

    public static func isSubAgentToolName(_ rawName: String) -> Bool {
        guard let canonicalName = canonicalSubAgentToolName(for: rawName) else {
            return false
        }
        return canonicalName.hasPrefix("agent.")
    }

    public static func canonicalSubAgentToolName(for rawName: String) -> String? {
        guard let canonicalName = OrchestrationToolRequestCompatibility.canonicalToolName(for: rawName),
              canonicalName.hasPrefix("agent.") else {
            return nil
        }
        return canonicalName
    }

    public func execute(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> String {
        let request = Self.normalizedToolRequest(for: toolCall)

        switch request.name {
        case "agent.create":
            return try await createAgents(
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                parentAllowedToolNames: allowedToolNames
            )
        case "agent.list":
            return listAgents(arguments: request.arguments)
        case "agent.get":
            return getAgents(arguments: request.arguments)
        case "agent.message":
            return try messageAgents(arguments: request.arguments)
        case "agent.wait":
            return await waitForAgents(arguments: request.arguments)
        case "agent.close":
            return try await closeAgent(arguments: request.arguments)
        default:
            throw DirectSubAgentRuntimeError.unknownTool(toolCall.name)
        }
    }
}
