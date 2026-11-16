//
//  ChatSessionTestSupport+ScriptedRuntimeTypes.swift
//  ZenCODE
//
//  The nested value types of the scripted chat runtime: the scripted call,
//  the session digest, the logged management operations and the read-only
//  queries.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension ScriptedChatRuntime {
    struct Call: Sendable {
        let index: Int
        let authorizeTool: AgentToolAuthorizationHandler?
        let onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?
        let onEvent: @Sendable (DirectAgentEvent) async -> Void
        let runtime: ScriptedChatRuntime
    }

    typealias Script = @Sendable (Call) async throws -> DirectAgentResponse

    enum ScriptError: Error {
        case missingScript(index: Int)
    }

    /// What a session-creating call received, reduced to what tests compare.
    struct SessionDigest: Equatable, Sendable {
        let sessionID: String
        let modelID: String?
        let agentID: String?
        let allowedToolNames: Set<String>?
        let thinkingSelection: AgentThinkingSelection?
        let historyContents: [String]

        init(_ configuration: AgentCoreSessionConfiguration) {
            sessionID = configuration.sessionID
            modelID = configuration.modelID
            agentID = configuration.agentID
            allowedToolNames = configuration.allowedToolNames
            thinkingSelection = configuration.thinkingSelection
            historyContents = configuration.history.map(\.content)
        }
    }

    /// An operation the controller asked of the runtime.
    enum ManagementCall: Equatable, Sendable {
        case createSession(SessionDigest)
        case restoreSession(SessionDigest)
        case updateSessionOptions(SessionDigest)
        case resetSession(String?)
        case rebuildSession(String)
        case shutdownBackendKeepingExternalTools
        case compactSession(sessionID: String, force: Bool, maxTokensOverride: Int?)
        case preloadModel(SessionDigest)
        case updatePromptSkillSelection(skillNames: [String], sessionID: String)
        case saveEngineCheckpoint(sessionID: String, fileName: String)
        case restoreEngineCheckpoint(sessionID: String, fileName: String)
        case restoreTaskGraph(graphID: String, sessionID: String)
        case clearTaskGraphs(sessionID: String)
        case deleteSavedTaskPlans(planIDs: [String])
        case activateTaskGraph(graphID: String, sessionID: String)
        case archiveTaskGraph(graphID: String, sessionID: String)
        case retryTask(taskID: String, sessionID: String, expectedRevision: Int?)
        case cancelTask(taskID: String, sessionID: String, reason: String?)
        case removeResumableTaskGraphs(ids: [String])
        case adoptResumableTaskGraph(id: String, intoSessionID: String)

        /// The operation's name, for asserting the order of a sequence.
        var name: String {
            switch self {
            case .createSession: "createSession"
            case .restoreSession: "restoreSession"
            case .updateSessionOptions: "updateSessionOptions"
            case .resetSession: "resetSession"
            case .rebuildSession: "rebuildSession"
            case .shutdownBackendKeepingExternalTools: "shutdownBackendKeepingExternalTools"
            case .compactSession: "compactSession"
            case .preloadModel: "preloadModel"
            case .updatePromptSkillSelection: "updatePromptSkillSelection"
            case .saveEngineCheckpoint: "saveEngineCheckpoint"
            case .restoreEngineCheckpoint: "restoreEngineCheckpoint"
            case .restoreTaskGraph: "restoreTaskGraph"
            case .clearTaskGraphs: "clearTaskGraphs"
            case .deleteSavedTaskPlans: "deleteSavedTaskPlans"
            case .activateTaskGraph: "activateTaskGraph"
            case .archiveTaskGraph: "archiveTaskGraph"
            case .retryTask: "retryTask"
            case .cancelTask: "cancelTask"
            case .removeResumableTaskGraphs: "removeResumableTaskGraphs"
            case .adoptResumableTaskGraph: "adoptResumableTaskGraph"
            }
        }

        /// The session configuration the operation carried, if it carried one.
        var digest: SessionDigest? {
            switch self {
            case let .createSession(digest),
                 let .restoreSession(digest),
                 let .updateSessionOptions(digest),
                 let .preloadModel(digest):
                digest
            default:
                nil
            }
        }
    }

    /// A read-only lookup the controller made.
    enum Query: Equatable, Sendable {
        case snapshotSession(String)
        case taskGraphSnapshot(String)
        case activeToolDescriptors(String)
        case knownMCPToolDescriptors
    }

    struct ScriptedFailure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }
}
