//
//  ZenWindowStatus.swift
//  ZenApp
//
//  The status bar of a window, and a line waiting in its queue.
//

import Foundation
import ZenCODECore

/// What the status bar of a window shows, as the terminal's status bar.
public struct ZenWindowStatus: Equatable, Sendable {
    /// A turn is generating (`ChatTurnState.isGenerating`).
    public var isGenerating: Bool
    /// When the turn that generates, or generated last, started.
    public var turnStartedAt: Date?
    /// The model of the next turn, or the launch model.
    public var modelID: String?
    /// The thinking level of the next turn.
    public var thinking: AgentThinkingSelection?
    /// The selected agent's name.
    public var agentName: String?
    /// The running metrics of the turn.
    public var metrics: DirectAgentGenerationMetrics?
    /// The context window of the session.
    public var contextWindow: DirectAgentContextWindowStatus?
    /// The subscription usage of the account.
    public var subscriptionUsage: DirectAgentSubscriptionUsageStatus?
    /// The working-tree summary; `nil` outside a git repository.
    public var gitStatus: TerminalGitStatusSummary?
    /// The window's workspace.
    public var workspace: URL
    /// The runner's access mode, the same in every window
    /// (``ZenAppRuntime/localExecAccessMode``).
    public var localExecAccessMode: AgentLocalExecAccessMode

    public init(
        isGenerating: Bool = false,
        turnStartedAt: Date? = nil,
        modelID: String? = nil,
        thinking: AgentThinkingSelection? = nil,
        agentName: String? = nil,
        metrics: DirectAgentGenerationMetrics? = nil,
        contextWindow: DirectAgentContextWindowStatus? = nil,
        subscriptionUsage: DirectAgentSubscriptionUsageStatus? = nil,
        gitStatus: TerminalGitStatusSummary? = nil,
        workspace: URL,
        localExecAccessMode: AgentLocalExecAccessMode = .standard
    ) {
        self.isGenerating = isGenerating
        self.turnStartedAt = turnStartedAt
        self.modelID = modelID
        self.thinking = thinking
        self.agentName = agentName
        self.metrics = metrics
        self.contextWindow = contextWindow
        self.subscriptionUsage = subscriptionUsage
        self.gitStatus = gitStatus
        self.workspace = workspace
        self.localExecAccessMode = localExecAccessMode
    }
}

/// What the welcome view of an empty session shows about the next turn, as
/// the terminal's startup summary: the selected agent, the active tools, and
/// the active skills. Read with the status bar.
public struct ZenStartupSummary: Equatable, Sendable {
    /// The selected agent's display name; `nil` without an agent.
    public var agentName: String?
    /// The tool groups the session exposes.
    public var activeTools: ChatActiveToolsSummary
    /// The skills the session selected.
    public var activeSkills: [PromptSkill]

    public init(
        agentName: String? = nil,
        activeTools: ChatActiveToolsSummary = ChatActiveToolsSummary(groups: []),
        activeSkills: [PromptSkill] = []
    ) {
        self.agentName = agentName
        self.activeTools = activeTools
        self.activeSkills = activeSkills
    }
}

/// A prompt waiting in a window's queue until the running line ends.
public struct ZenQueuedLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Why a window or the app could not launch.
public enum ZenAppLaunchFailure: Error, Sendable, Equatable {
    /// The settings could not be read: setup has not run.
    case notConfigured(String)
    /// An argument of the launch is wrong (an unknown agent, a missing or
    /// invalid value): the description of the error, shown without the setup
    /// hint of ``notConfigured(_:)``.
    case invalidArguments(String)
    /// The configuration was read, but the app could not start.
    case startFailed(String)

    /// The text the app shows.
    public var message: String {
        switch self {
        case let .notConfigured(message), let .startFailed(message):
            message
        case let .invalidArguments(description):
            "ZenCODE: \(description)"
        }
    }

    /// The text of ``notConfigured(_:)``, before the error description.
    public static let notConfiguredMessage =
        "ZenCODE is not configured. Run `zen` in a terminal to complete the setup, then start the app again."
}
