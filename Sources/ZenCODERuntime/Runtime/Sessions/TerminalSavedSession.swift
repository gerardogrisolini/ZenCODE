//
//  TerminalSavedSession.swift
//  ZenCODE
//
//  The saved session file format: the persisted session with its context
//  window, and the header that lookups decode without the conversation.
//

import Foundation
import ToolCore

public struct TerminalSavedSessionContextWindow: Codable, Equatable, Sendable {
    public let usedTokens: Int?
    public let maxTokens: Int?
    public let modelID: String
    public let isApproximate: Bool

    public init(
        usedTokens: Int?,
        maxTokens: Int?,
        modelID: String,
        isApproximate: Bool
    ) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isApproximate = isApproximate
    }

    public init(_ status: DirectAgentContextWindowStatus) {
        self.init(
            usedTokens: status.usedTokens,
            maxTokens: status.maxTokens,
            modelID: status.modelID,
            isApproximate: status.isApproximate
        )
    }

    public var runtimeStatus: DirectAgentContextWindowStatus? {
        guard !modelID.isEmpty else {
            return nil
        }
        return DirectAgentContextWindowStatus(
            usedTokens: usedTokens,
            maxTokens: maxTokens,
            modelID: modelID,
            isApproximate: isApproximate
        )
    }
}

public struct TerminalSavedSession: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    /// ``autosaveChannel`` of a session the ACP bridge (`zen --acp`) saved by
    /// itself at the end of a turn.
    public static let acpAutosaveChannel = "acp"

    public let version: Int
    public let name: String
    public let sessionID: String
    public let cacheKey: String?
    public let workingDirectoryPath: String
    public let createdAt: Date
    public let savedAt: Date
    public let modelID: String?
    public let agentID: String?
    public let agentName: String?
    public let selectedTools: [String]
    /// Canonical names of the selected prompt skills. Sessions saved before
    /// the name became the only skill identifier carry `selectedSkillIDs`
    /// instead: that key is ignored and they decode with no skill selected.
    public let selectedSkillNames: [String]
    public let thinkingSelection: String?
    public let contextWindow: TerminalSavedSessionContextWindow?
    public let systemPrompt: String?
    /// Mutable context stored separately from the stable system prompt (v5+).
    /// Optional decoding keeps v1–v4 snapshots restorable as legacy prompts.
    public let dynamicContext: String?
    public let history: [AgentRuntimeMessage]
    public let transcriptHistory: [AgentRuntimeMessage]?
    public let activePlan: TerminalSessionPlan?
    /// Plans that follow `activePlan` in a Planner sequence, in order. Sessions
    /// saved without it decode to `nil`; the writer sets it only when the queue
    /// is non-empty, so existing files and sessions without a queue encode
    /// identically (no new key, no version bump).
    public let queuedPlans: [TerminalSessionPlan]?
    public let taskGraph: TaskGraphSnapshot?
    /// Session checkpoint tree (v4+).
    public let checkpointTree: SessionCheckpointTree
    /// The channel that saved the session by itself, without a command
    /// (``acpAutosaveChannel``); `nil` for a session saved with `/sessions`.
    /// Sessions saved without it decode to `nil`, and the writer omits the key
    /// when it is `nil`, so existing files and the sessions saved with a
    /// command encode identically (no new key, no version bump).
    public let autosaveChannel: String?

    public init(
        version: Int = Self.currentVersion,
        name: String,
        sessionID: String,
        cacheKey: String?,
        workingDirectoryPath: String,
        createdAt: Date,
        savedAt: Date,
        modelID: String?,
        agentID: String?,
        agentName: String?,
        selectedTools: [String],
        selectedSkillNames: [String],
        thinkingSelection: String?,
        contextWindow: TerminalSavedSessionContextWindow? = nil,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage]? = nil,
        activePlan: TerminalSessionPlan? = nil,
        queuedPlans: [TerminalSessionPlan]? = nil,
        taskGraph: TaskGraphSnapshot? = nil,
        checkpointTree: SessionCheckpointTree,
        autosaveChannel: String? = nil
    ) {
        self.version = version
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cacheKey = cacheKey?.nilIfBlank
        self.workingDirectoryPath = URL(fileURLWithPath: workingDirectoryPath)
            .standardizedFileURL
            .path
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.modelID = modelID?.nilIfBlank
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
        self.selectedTools = selectedTools
        self.selectedSkillNames = selectedSkillNames
        self.thinkingSelection = thinkingSelection?.nilIfBlank
        self.contextWindow = contextWindow
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.dynamicContext = dynamicContext?.nilIfBlank
        self.history = history
        self.transcriptHistory = transcriptHistory
        self.activePlan = activePlan
        self.queuedPlans = queuedPlans
        self.taskGraph = taskGraph
        self.checkpointTree = checkpointTree
        self.autosaveChannel = autosaveChannel?.nilIfBlank
    }

    /// Decodes exactly what the synthesized conformance would, except that
    /// `selectedSkillNames` may be absent (a session saved while skills were
    /// identified by id) and then decodes as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.name = try container.decode(String.self, forKey: .name)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
        self.workingDirectoryPath = try container.decode(String.self, forKey: .workingDirectoryPath)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.savedAt = try container.decode(Date.self, forKey: .savedAt)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        self.agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.selectedTools = try container.decode([String].self, forKey: .selectedTools)
        self.selectedSkillNames = try container.decodeIfPresent([String].self, forKey: .selectedSkillNames) ?? []
        self.thinkingSelection = try container.decodeIfPresent(String.self, forKey: .thinkingSelection)
        self.contextWindow = try container.decodeIfPresent(
            TerminalSavedSessionContextWindow.self,
            forKey: .contextWindow
        )
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.dynamicContext = try container.decodeIfPresent(String.self, forKey: .dynamicContext)
        self.history = try container.decode([AgentRuntimeMessage].self, forKey: .history)
        self.transcriptHistory = try container.decodeIfPresent(
            [AgentRuntimeMessage].self,
            forKey: .transcriptHistory
        )
        self.activePlan = try container.decodeIfPresent(TerminalSessionPlan.self, forKey: .activePlan)
        self.queuedPlans = try container.decodeIfPresent([TerminalSessionPlan].self, forKey: .queuedPlans)
        self.taskGraph = try container.decodeIfPresent(TaskGraphSnapshot.self, forKey: .taskGraph)
        self.checkpointTree = try container.decode(SessionCheckpointTree.self, forKey: .checkpointTree)
        self.autosaveChannel = try container.decodeIfPresent(String.self, forKey: .autosaveChannel)
    }

    public var displayHistory: [AgentRuntimeMessage] {
        transcriptHistory ?? history
    }

    public var messageCount: Int {
        displayHistory.filter { $0.role != .system }.count
    }
}

/// What a saved session file says about itself before its conversation: which
/// session it is, where and when it was saved, and whether a channel saved it
/// by itself (``TerminalSavedSession/autosaveChannel``). Decoded without the
/// history, the transcript, the plans, the task graph, or the checkpoint tree.
package struct TerminalSavedSessionHeader: Decodable, Equatable, Sendable {
    let version: Int
    package let name: String
    package let sessionID: String
    package let workingDirectoryPath: String
    package let createdAt: Date
    package let savedAt: Date
    let autosaveChannel: String?
}

/// A saved session file and its header.
package struct TerminalSavedSessionFile: Equatable, Sendable {
    package let url: URL
    package let header: TerminalSavedSessionHeader
}
