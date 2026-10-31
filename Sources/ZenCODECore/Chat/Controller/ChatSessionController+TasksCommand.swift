//
//  ChatSessionController+TasksCommand.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// `/tasks`, shared by every channel: the current task graph (`status`,
/// `list`, `ls`, the default), one task (`show`, `get`), and the task
/// lifecycle (`retry`, `cancel`, `clear`).
///
/// The echo of the line goes to the presenter first, for every action. The
/// graph is presented as an ``ChatOverviewOrigin/explicit`` overview through
/// ``ChatSessionPresenter/presentTaskGraphOverview(_:origin:publication:)``,
/// with a reservation taken before the graph is read. The confirmation of a
/// retry or a cancellation is presented as it happens, before the graph that
/// shows its effect; everything else is in the outcome's notices. Retry,
/// cancel, and clear change the task graphs, which a controller created
/// without a ``ChatSessionManagementRuntime`` cannot do.
extension ChatSessionController {
    /// `/tasks` and its actions. `line` is the submitted command line.
    func runTasksCommand(line: String) async -> ChatCommandOutcome {
        await presenter.presentSubmittedCommand(line)
        let argument = ChatCommandRegistry.arguments(from: line, commandPrefix: "/tasks")
        let components = argument.split(whereSeparator: \.isWhitespace).map(String.init)
        let action = components.first?.lowercased() ?? "status"

        do {
            switch action {
            case "status", "list", "ls":
                return ChatCommandOutcome(notices: try await presentCurrentTaskGraph())
            case "show", "get":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                let view = try await runtime.taskOrchestrator.task(
                    sessionID: sessionID,
                    taskID: components[1]
                )
                return ChatCommandOutcome(notices: [.taskDetail(view)])
            case "retry":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                _ = try await requiredManagementRuntime().retryTask(
                    id: components[1],
                    sessionID: sessionID,
                    expectedRevision: nil
                )
                await presenter.presentSessionNotice(.taskRetried(taskID: components[1]))
                return ChatCommandOutcome(notices: try await presentCurrentTaskGraph())
            case "cancel":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                let reason = components.dropFirst(2).joined(separator: " ").nilIfBlank
                _ = try await requiredManagementRuntime().cancelTask(
                    id: components[1],
                    sessionID: sessionID,
                    reason: reason
                )
                await presenter.presentSessionNotice(.taskCancelled(taskID: components[1]))
                return ChatCommandOutcome(notices: try await presentCurrentTaskGraph())
            case "clear":
                try await requiredManagementRuntime().clearTaskGraphs(sessionID: sessionID)
                return ChatCommandOutcome(notices: [.taskGraphsCleared])
            default:
                throw TerminalTaskCommandError.unknownAction(action)
            }
        } catch let error as TerminalTaskCommandError {
            switch error {
            case let .missingTaskID(action):
                return ChatCommandOutcome(notices: [.taskIDRequired(action: action)])
            case let .unknownAction(action):
                return ChatCommandOutcome(notices: [.unknownTasksAction(action: action)])
            }
        } catch {
            return ChatCommandOutcome(
                notices: [.operationFailed(description: error.localizedDescription)]
            )
        }
    }

    /// Presents the session's current task graph as an explicit overview and
    /// returns the closing notices: none, or ``ChatSessionNotice/noTaskGraph``.
    /// The publication is reserved before the graph is read, so a publication
    /// that started earlier cannot overtake it.
    private func presentCurrentTaskGraph() async throws -> [ChatSessionNotice] {
        let publication = await presenter.reserveTaskGraphOverviewPublication()
        guard let overview = try await ChatTaskGraphOverview.current(
            in: runtime,
            sessionID: sessionID
        ) else {
            return [.noTaskGraph]
        }
        await presenter.presentTaskGraphOverview(
            overview,
            origin: .explicit,
            publication: publication
        )
        return []
    }
}
