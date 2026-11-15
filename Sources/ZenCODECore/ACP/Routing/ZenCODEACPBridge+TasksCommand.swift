//
//  ZenCODEACPBridge+TasksCommand.swift
//  ZenCODE
//
//  ACP answer to /tasks: the session task graph the terminal and Telegram
//  show, and the `plan` update that is the Tasks section of an ACP client.
//

import Foundation

/// `/tasks` in an ACP session: the graph (`status`, `list`, `ls`, the
/// default), one task (`show`, `get`), the lifecycle (`retry`, `cancel`), and
/// `clear`, on the shared command
/// (``ChatSessionController/runTasksCommand(line:)``), which runs the action
/// and answers its notices.
///
/// ACP has no terminal to draw the graph in and its session presenter is
/// silent, so the graph is read here and written twice: as the text the
/// terminal and Telegram render (``TerminalTaskGraphLayout``, without colors),
/// and as the standard ACP `plan` update with one entry per task, the section
/// a client shows as the session's tasks and that a prompt otherwise publishes
/// only while it generates. The session's task presentation acknowledges the
/// plan, so the next prompt does not send the same one again. A snapshot that
/// cannot be read answers its notices and publishes no plan: an unavailable
/// read is not an authoritative clear.
///
/// The actions that change the graph run as the terminal's do, before the
/// fence is read again: a `/tasks` the session no longer holds ends
/// `cancelled`, as every command routed on a fence does.
extension ZenCODEACPBridge {
    static let tasksCommandToken = "/tasks"

    /// The actions whose answer carries the graph itself.
    private static let tasksGraphActions: Set<String> = ["status", "list", "ls", "retry", "cancel", "clear"]

    /// The answer to the `/tasks` line `line` of the prompt that holds the
    /// reservation `promptID`.
    func routeACPTasksCommand(
        _ line: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        fence: ChatCommandFence
    ) async throws -> ACPCommandTurnRoute {
        guard let session = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        let controller = session.controller
        let outcome = await controller.runTasksCommand(line: line)
        guard controller.isCurrent(fence) else {
            throw CancellationError()
        }

        var texts = outcome.notices.map { Self.acpText(for: $0, context: .tasks) }
        let action = Self.tasksAction(of: line)
        if Self.tasksGraphActions.contains(action),
           Self.presentsGraph(after: outcome.notices) {
            do {
                let overview = try await ChatTaskGraphOverview.current(in: sessionRunner, sessionID: sessionID)
                await publishTasksPlan(overview?.graph, sessionID: sessionID, epoch: epoch)
                if let overview {
                    texts.append(Self.taskGraphText(overview))
                } else if texts.isEmpty {
                    texts.append(Self.acpText(for: .noTaskGraph, context: .tasks))
                }
            } catch {
                // An unavailable snapshot is not an authoritative clear: the
                // failure is the answer, and no plan is published.
                texts.append(Self.acpText(
                    for: .operationFailed(description: error.localizedDescription),
                    context: .tasks
                ))
            }
        }
        return .immediate(texts.joined(separator: "\n\n"))
    }

    /// The action the line asks for: its first argument in lowercase, or the
    /// default the shared command runs.
    static func tasksAction(of line: String) -> String {
        ChatCommandRegistry.arguments(
            from: line.trimmingCharacters(in: .whitespacesAndNewlines),
            commandPrefix: tasksCommandToken
        )
        .split(whereSeparator: \.isWhitespace)
        .first
        .map { $0.lowercased() }
            ?? "status"
    }

    /// Whether the graph is presented after the command: every notice its
    /// action answered is about the graph's presence (`/tasks clear`, or a
    /// read that found none), so a failure and a missing argument keep their
    /// text alone.
    private static func presentsGraph(after notices: [ChatSessionNotice]) -> Bool {
        notices.allSatisfy { notice in
            switch notice {
            case .noTaskGraph, .taskGraphsCleared:
                return true
            default:
                return false
            }
        }
    }

    /// The graph as the terminal and Telegram write it, without colors: the
    /// summary of the statuses, the identity of the graph, and a row per task.
    static func taskGraphText(_ overview: ChatTaskGraphOverview) -> String {
        TerminalANSIText.stripANSI(
            TerminalTaskGraphLayout.markdown(
                graph: overview.graph,
                tasks: overview.tasks,
                ansiEnabled: false
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the `plan` update of `graph` — the client's Tasks section — and
    /// acknowledges it as presented, so the next publication does not send the
    /// same plan again. The command presents the graph it answers with even when
    /// the section already shows it, which is what makes the answer and the
    /// section agree after a retry, a cancellation, or a clear.
    private func publishTasksPlan(
        _ graph: TaskGraphSnapshot?,
        sessionID: String,
        epoch: UInt64
    ) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        // A prompt that owns the presentation publishes the section itself,
        // through its pipeline; this command never overtakes it.
        guard session.promptUpdatePipeline == nil else { return }
        guard let plan = await session.taskPresentation.planToPresent(for: graph, force: true) else {
            return
        }
        guard liveSession(id: sessionID, epoch: epoch) != nil else { return }
        await writer.sendSessionUpdate(sessionID: sessionID, update: plan)
        await session.taskPresentation.acknowledge(plan)
    }
}
