//
//  TerminalChat+ResumeTaskGraph.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    enum ResumableTaskGraphChoice: Hashable, Sendable {
        case resume(String)
        case deleteOld
        case startFresh
    }

    /// Detects incomplete task graphs persisted by previous sessions and, in an
    /// interactive terminal, offers to resume one. When the user confirms a
    /// choice, the orchestrator restores the checkpoint and makes that exact
    /// graph current before `sessionID` is switched. The later session creation
    /// therefore cannot silently fall back to another graph from the same
    /// checkpoint. Returns the resumed graph (if any) so the caller can print a
    /// notice after the startup screen has been rendered.
    ///
    /// Non-interactive (piped) input and ACP mode are skipped: resuming requires
    /// a choice the operator can make without contaminating ACP JSON-RPC I/O.
    func applyResumableTaskGraphSessionIfNeeded() async -> ResumableTaskGraph? {
        guard Self.shouldOfferResumableTaskGraphSelection(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal
        ) else {
            return nil
        }
        let workingDirectory = configuration.workingDirectory
        var resumable = await sessionRunner.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        )
        while !resumable.isEmpty {
            guard let choice = await TerminalCheckboxMenu.selectOneOffActor(
                title: "Open tasks from previous sessions",
                items: Self.resumableTaskGraphChoiceItems(resumable),
                selected: .resume(resumable[0].id)
            ) else {
                return nil
            }

            switch choice {
            case let .resume(id):
                guard let chosen = resumable.first(where: { $0.id == id }) else {
                    return nil
                }
                do {
                    _ = try await sessionRunner.resumeTaskGraph(
                        chosen,
                        workingDirectory: workingDirectory
                    )
                    sessionID = chosen.sessionID
                    return chosen
                } catch {
                    await writeSystemMessage(
                        "Could not resume \(chosen.graphID): \(error.localizedDescription)\n"
                    )
                    resumable = await sessionRunner.resumableTaskGraphCheckpoints(
                        workingDirectory: workingDirectory
                    )
                }
            case .startFresh:
                return nil
            case .deleteOld:
                await deleteOldResumableTaskGraphs(
                    resumable,
                    workingDirectory: workingDirectory
                )
                resumable = await sessionRunner.resumableTaskGraphCheckpoints(
                    workingDirectory: workingDirectory
                )
            }
        }
        return nil
    }

    nonisolated static func shouldOfferResumableTaskGraphSelection(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool
    ) -> Bool {
        guard stdinIsTerminal else { return false }
        switch configuration.resolvedRunMode(stdinIsTerminal: stdinIsTerminal) {
        case .chat:
            return true
        case .acp:
            return false
        }
    }

    nonisolated static func resumableTaskGraphChoiceItems(
        _ graphs: [ResumableTaskGraph]
    ) -> [TerminalCheckboxMenuItem<ResumableTaskGraphChoice>] {
        let graphItems: [TerminalCheckboxMenuItem<ResumableTaskGraphChoice>] = graphs.map { graph in
            TerminalCheckboxMenuItem(
                value: ResumableTaskGraphChoice.resume(graph.id),
                title: graph.graphID,
                detail: "\(graph.pendingTaskCount) of \(graph.totalTaskCount) tasks pending"
                    + " · updated \(savedSessionTimestamp(graph.updatedAt))",
                groupTitle: "Resume"
            )
        }
        return graphItems + [
            TerminalCheckboxMenuItem(
                value: .deleteOld,
                title: "Delete old tasks…",
                detail: "select obsolete task graphs with x",
                groupTitle: "Other actions"
            ),
            TerminalCheckboxMenuItem(
                value: .startFresh,
                title: "Start fresh",
                detail: "leave saved tasks unchanged",
                groupTitle: "Other actions"
            ),
        ]
    }

    nonisolated static func resumableTaskGraphDeletionItems(
        _ graphs: [ResumableTaskGraph]
    ) -> [TerminalCheckboxMenuItem<String>] {
        graphs.map { graph in
            TerminalCheckboxMenuItem(
                value: graph.id,
                title: graph.graphID,
                detail: "\(graph.pendingTaskCount) pending"
                    + " · updated \(savedSessionTimestamp(graph.updatedAt))"
            )
        }
    }

    private func deleteOldResumableTaskGraphs(
        _ graphs: [ResumableTaskGraph],
        workingDirectory: URL
    ) async {
        guard let selectedIDs = await TerminalCheckboxMenu.selectOffActor(
            title: "Delete old tasks",
            items: Self.resumableTaskGraphDeletionItems(graphs),
            selected: []
        ), !selectedIDs.isEmpty else {
            return
        }
        let selectedGraphs = graphs.filter { selectedIDs.contains($0.id) }
        do {
            try await sessionRunner.removeResumableTaskGraphs(
                selectedGraphs,
                workingDirectory: workingDirectory
            )
            await writeSystemMessage(
                "Deleted \(selectedGraphs.count) old task graph"
                    + "\(selectedGraphs.count == 1 ? "" : "s").\n"
            )
        } catch {
            await writeSystemMessage("Could not delete old tasks: \(error.localizedDescription)\n")
        }
    }

    func writeResumedTaskGraphNotice(_ graph: ResumableTaskGraph) async {
        await writeSystemMessage(
            "Resumed task graph \"\(graph.graphID)\" from a previous session "
            + "(\(graph.pendingTaskCount) task\(graph.pendingTaskCount == 1 ? "" : "s") pending). "
            + "Use /tasks to review it.\n"
        )
    }
}
