//
//  ChatSessionController+ResumeTaskGraph.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// What the startup offer of the task graphs left incomplete by earlier
/// sessions did (see ``ChatSessionController/offerResumableTaskGraphs(choiceHost:)``).
public struct ChatTaskGraphResumeOutcome: Sendable, Equatable {
    /// The graph adopted into the session, `nil` when the operator started
    /// fresh, cancelled, deleted every graph, or nothing was offered.
    public let resumedGraph: ResumableTaskGraph?
    /// The notices of the offer, in order: the deletions, the failed
    /// resumptions, and last the resumption. The offer presents none of them:
    /// the channel presents them when it is ready, after its startup screen
    /// (see ``ChatSessionController/presentSessionNotices(_:)``).
    public let notices: [ChatSessionNotice]

    public init(
        resumedGraph: ResumableTaskGraph? = nil,
        notices: [ChatSessionNotice] = []
    ) {
        self.resumedGraph = resumedGraph
        self.notices = notices
    }

    /// Nothing was offered and nothing changed.
    public static let none = ChatTaskGraphResumeOutcome()
}

/// The startup recovery shared by every channel: the task graphs that earlier
/// sessions of the project left incomplete are offered once, before the first
/// prompt, through the ``ChatInteractionHost`` menus, and the one the operator
/// resumes is moved into this controller's session, which keeps its id
/// (``ChatSessionManagementRuntime/adoptResumableTaskGraph(_:intoSessionID:workingDirectory:)``).
/// The same mechanism serves the terminal, Telegram, ACP, and the app, so
/// none of them adopts the id of the session that left the graph.
extension ChatSessionController {
    // MARK: - Choice IDs

    /// The ID of the main-menu item that deletes old graphs. Stable: a channel
    /// may map the IDs of this menu onto its own vocabulary (ACP maps them to
    /// the kinds of its permission options).
    nonisolated static let resumableTaskGraphDeleteChoiceID = "delete"

    /// The ID of the main-menu item that starts fresh, leaving every saved
    /// graph where it is. Stable, like ``resumableTaskGraphDeleteChoiceID``.
    nonisolated static let resumableTaskGraphStartFreshChoiceID = "fresh"

    /// The ID of the main-menu item that resumes `graph`: `resume:` followed by
    /// the graph's ``ResumableTaskGraph/id`` (`<session>/<graph>`), unique
    /// across the checkpoints of the project. Stable, like
    /// ``resumableTaskGraphDeleteChoiceID``.
    nonisolated static func resumableTaskGraphResumeChoiceID(
        for graph: ResumableTaskGraph
    ) -> String {
        "resume:" + graph.id
    }

    // MARK: - Menus

    /// The main menu: one item per graph under `Resume`, in list order, then
    /// under `Other actions` the deletion and `Start fresh`. `deletesAll` is
    /// a host without ``ChatChannelCapabilities/multipleChoice``, whose
    /// deletion cannot ask which graphs and so deletes every one listed.
    nonisolated static func resumableTaskGraphChoiceItems(
        _ graphs: [ResumableTaskGraph],
        deletesAll: Bool
    ) -> [ChatChoiceItem] {
        let graphItems = graphs.map { graph in
            ChatChoiceItem(
                id: resumableTaskGraphResumeChoiceID(for: graph),
                title: graph.graphID,
                detail: "\(graph.pendingTaskCount) of \(graph.totalTaskCount) tasks pending"
                    + " · updated \(ChatSessionNoticeText.timestampText(graph.updatedAt))",
                group: "Resume"
            )
        }
        let deleteItem = deletesAll
            ? ChatChoiceItem(
                id: resumableTaskGraphDeleteChoiceID,
                title: "Delete all old tasks",
                detail: "delete every task graph listed above",
                group: "Other actions"
            )
            : ChatChoiceItem(
                id: resumableTaskGraphDeleteChoiceID,
                title: "Delete old tasks…",
                detail: "choose the obsolete task graphs to delete",
                group: "Other actions"
            )
        return graphItems + [
            deleteItem,
            ChatChoiceItem(
                id: resumableTaskGraphStartFreshChoiceID,
                title: "Start fresh",
                detail: "leave saved tasks unchanged",
                group: "Other actions"
            ),
        ]
    }

    /// The deletion menu: one item per graph, identified by its
    /// ``ResumableTaskGraph/id``.
    nonisolated static func resumableTaskGraphDeletionItems(
        _ graphs: [ResumableTaskGraph]
    ) -> [ChatChoiceItem] {
        graphs.map { graph in
            ChatChoiceItem(
                id: graph.id,
                title: graph.graphID,
                detail: "\(graph.pendingTaskCount) pending"
                    + " · updated \(ChatSessionNoticeText.timestampText(graph.updatedAt))"
            )
        }
    }

    // MARK: - Offer

    /// Offers the task graphs that earlier sessions of the project left
    /// incomplete: resume one, delete old ones, or start fresh, until the
    /// operator resumes one, starts fresh, or cancels, or nothing is left to
    /// offer.
    ///
    /// Channels call it once at startup, before the first prompt. It works
    /// before the runtime session exists (the terminal, whose later session
    /// creation finds the adopted graph) and after (an open app window or ACP
    /// session): the graph is moved into ``sessionID`` either way, and the
    /// session keeps its id. A resumed non-terminal `/goal` workflow arms its
    /// continuation, so the next message continues it on the same graph.
    ///
    /// `choiceHost` asks instead of ``host`` (a channel whose startup host is
    /// not yet the session's). Nothing is offered without a
    /// ``managementRuntime`` or when the host lacks
    /// ``ChatChannelCapabilities/singleChoice``; without
    /// ``ChatChannelCapabilities/multipleChoice`` the deletion deletes every
    /// listed graph. The graphs of this session and of the sessions another
    /// slot of the host runs now (``ChatSessionHost/liveSessionIDs()``) are
    /// left out: they are not left over, and two windows never adopt the same
    /// graph.
    ///
    /// The notices are returned, not presented: the caller presents them when
    /// it is ready (``presentSessionNotices(_:)``).
    public func offerResumableTaskGraphs(
        choiceHost: (any ChatInteractionHost)? = nil
    ) async -> ChatTaskGraphResumeOutcome {
        let host = choiceHost ?? self.host
        guard let managementRuntime,
              host.capabilities.contains(.singleChoice) else {
            return .none
        }
        var notices: [ChatSessionNotice] = []
        var resumable = await offerableResumableTaskGraphs(on: managementRuntime)
        guard !resumable.isEmpty else {
            return .none
        }
        let deletesAll = !host.capabilities.contains(.multipleChoice)

        while !resumable.isEmpty, !Task.isCancelled {
            guard let choiceID = await host.chooseOne(
                title: "Open tasks from previous sessions",
                items: Self.resumableTaskGraphChoiceItems(resumable, deletesAll: deletesAll),
                selectedID: Self.resumableTaskGraphResumeChoiceID(for: resumable[0])
            ), !Task.isCancelled else {
                break
            }

            switch choiceID {
            case Self.resumableTaskGraphStartFreshChoiceID:
                return ChatTaskGraphResumeOutcome(notices: notices)

            case Self.resumableTaskGraphDeleteChoiceID:
                let selectedGraphs: [ResumableTaskGraph]
                if deletesAll {
                    selectedGraphs = resumable
                } else {
                    guard let selectedIDs = await host.chooseMany(
                        title: "Delete old tasks",
                        items: Self.resumableTaskGraphDeletionItems(resumable),
                        selectedIDs: []
                    ) else {
                        // Cancelled: back to the main menu.
                        continue
                    }
                    selectedGraphs = resumable.filter { selectedIDs.contains($0.id) }
                }
                guard !selectedGraphs.isEmpty, !Task.isCancelled else {
                    continue
                }
                do {
                    try await managementRuntime.removeResumableTaskGraphs(
                        selectedGraphs,
                        workingDirectory: workingDirectory
                    )
                    notices.append(.oldTaskGraphsDeleted(count: selectedGraphs.count))
                } catch {
                    notices.append(.oldTaskGraphsDeleteFailed(description: error.localizedDescription))
                }
                resumable = await offerableResumableTaskGraphs(on: managementRuntime)

            default:
                guard let chosen = resumable.first(where: {
                    Self.resumableTaskGraphResumeChoiceID(for: $0) == choiceID
                }) else {
                    // An ID this menu never offered: treated as a refusal.
                    return ChatTaskGraphResumeOutcome(notices: notices)
                }
                do {
                    let snapshot = try await managementRuntime.adoptResumableTaskGraph(
                        chosen,
                        intoSessionID: sessionID,
                        workingDirectory: workingDirectory
                    )
                    let resumesWorkflow = snapshot.source.isWorkflow && !snapshot.state.isTerminal
                    if resumesWorkflow {
                        // A resumed workflow keeps its `/goal` contract: the
                        // continuation round-trip of a clarification question
                        // makes the next message resume the coordinator on
                        // this exact graph instead of an unrelated turn.
                        restoreWorkflowProjection(from: snapshot)
                    }
                    notices.append(.taskGraphResumed(
                        graphID: snapshot.id,
                        pendingTaskCount: snapshot.tasks.lazy.filter { !$0.status.isTerminal }.count,
                        isWorkflow: resumesWorkflow
                    ))
                    return ChatTaskGraphResumeOutcome(resumedGraph: chosen, notices: notices)
                } catch {
                    notices.append(.taskGraphResumeFailed(
                        graphID: chosen.graphID,
                        description: error.localizedDescription
                    ))
                    resumable = await offerableResumableTaskGraphs(on: managementRuntime)
                }
            }
        }
        return ChatTaskGraphResumeOutcome(notices: notices)
    }

    /// Presents `notices` in order on the controller's presenter, observers
    /// first, as an operation presents the notices raised while it runs: for
    /// the outcome of ``offerResumableTaskGraphs(choiceHost:)``, which a
    /// channel presents once its startup screen is drawn.
    public func presentSessionNotices(_ notices: [ChatSessionNotice]) async {
        for notice in notices {
            await effectivePresenter(for: nil).presentSessionNotice(notice)
        }
    }

    /// The resumable graphs of the project, without those of this session
    /// and of the sessions the host's other slots run now.
    private func offerableResumableTaskGraphs(
        on managementRuntime: any ChatSessionManagementRuntime
    ) async -> [ResumableTaskGraph] {
        var excludedSessionIDs = hostBinding?.host?.liveSessionIDs() ?? []
        excludedSessionIDs.insert(sessionID)
        return await managementRuntime.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        )
        .filter { !excludedSessionIDs.contains($0.sessionID) }
    }
}
