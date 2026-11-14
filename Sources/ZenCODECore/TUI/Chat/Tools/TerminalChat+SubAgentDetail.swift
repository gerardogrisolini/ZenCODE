//
//  TerminalChat+SubAgentDetail.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// What `/subagent <name|id>` found among the sub-agents in progress.
    enum SubAgentMatch: Sendable {
        /// The agent to open.
        case matched(DirectSubAgentRuntime.AgentSnapshot)
        /// No agent, or more than one, matches: the message to write.
        case failed(message: String)
    }

    /// What `/subagent` opens: an agent's detail, or the list of the agents
    /// in progress.
    enum SubAgentDetailTarget {
        case agent(DirectSubAgentRuntime.AgentSnapshot)
        case choosing([DirectSubAgentRuntime.AgentSnapshot])
    }

    /// The input panel's mode while the detail shows an agent. It is no
    /// overlay of the prompt: below the detail the operator keeps typing,
    /// completing and sending the draft.
    nonisolated static let subAgentDetailPanelOverride = TerminalPanelModeOverride(
        modeText: "Sub-agent",
        helpText: "↑↓ PgUp PgDn Home End scroll · Esc close"
    )

    /// The input panel's mode while the detail lists the agents in progress,
    /// which own every key of the panel until one is opened.
    nonisolated static let subAgentListPanelOverride = TerminalPanelModeOverride(
        modeText: "Sub-agent",
        helpText: "↑↓ choose · Enter open · Esc close"
    )

    /// The input panel's mode that goes with each routing of the panel keys
    /// to the detail: ``subAgentListPanelOverride`` for the agent list,
    /// ``subAgentDetailPanelOverride`` for an agent's detail, none once the
    /// detail is closed.
    nonisolated static func subAgentPanelModeOverride(
        for mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) -> TerminalPanelModeOverride? {
        switch mode {
        case .closed: nil
        case .list: subAgentListPanelOverride
        case .detail: subAgentDetailPanelOverride
        }
    }

    // MARK: - Matching

    /// The sub-agent `argument` names among `snapshots`, the sub-agents in
    /// progress. The argument is trimmed; an agent whose id equals it,
    /// ignoring case, always wins, then the agents whose name equals it,
    /// ignoring case. No agent, or more than one by name, answers the message
    /// to write: the agents in progress (their name, else their id), or the
    /// agents with that name and their ids.
    nonisolated static func matchSubAgent(
        argument: String,
        in snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> SubAgentMatch {
        let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        func equals(_ value: String) -> Bool {
            value.caseInsensitiveCompare(argument) == .orderedSame
        }
        if !argument.isEmpty, let snapshot = snapshots.first(where: { equals($0.id) }) {
            return .matched(snapshot)
        }
        let named = argument.isEmpty
            ? []
            : snapshots.filter { $0.name.nilIfBlank.map(equals) == true }
        switch named.count {
        case 1:
            return .matched(named[0])
        case 0:
            let inProgress = snapshots
                .map { $0.name.nilIfBlank ?? $0.id }
                .joined(separator: ", ")
            return .failed(
                message: "ZenCODE: no sub-agent in progress matches '\(argument)'. In progress: \(inProgress).\n"
            )
        default:
            let candidates = named
                .map { "\($0.name.nilIfBlank ?? $0.id) (\($0.id))" }
                .joined(separator: ", ")
            return .failed(
                message: "ZenCODE: more than one sub-agent in progress is named '\(argument)': \(candidates). Use /subagent <id>.\n"
            )
        }
    }

    // MARK: - /subagent

    /// `/subagent [name|id]`: opens the live detail of a sub-agent in
    /// progress, directly when the argument names one or when only one is in
    /// progress, otherwise from the list of the agents in progress. It
    /// replaces a panel already open (a detail, or the `/artifacts` panel).
    ///
    /// The detail needs the interactive layout (``detailPanelScreen()``);
    /// otherwise, and when no sub-agent is in progress, it writes why and
    /// opens nothing. A failed match leaves an open panel as it is.
    ///
    /// The agent list owns every key of the panel. An agent's detail takes
    /// only the keys that scroll it and `Esc`, which closes it: the prompt
    /// keeps the other keys, so prompts and `@` mentions are typed and sent
    /// while it stays open, and a command goes on with it open unless it
    /// opens a menu or a line prompt
    /// (``closeDetailPanelForModalInput()``).
    func handleSubAgentCommand(_ command: String) async {
        guard let screen = detailPanelScreen() else {
            await writeFailureMessage("ZenCODE: /subagent requires the interactive terminal layout.\n")
            return
        }
        let pending = await sessionRunner.subAgentSnapshots().filter(\.pending)
        guard !pending.isEmpty else {
            await writeFailureMessage("ZenCODE: no sub-agent is in progress.\n")
            return
        }

        let argument = Self.slashCommandArguments(from: command, commandPrefix: "/subagent")
        let target: SubAgentDetailTarget
        if !argument.isEmpty {
            switch Self.matchSubAgent(argument: argument, in: pending) {
            case let .matched(snapshot):
                target = .agent(snapshot)
            case let .failed(message):
                await writeFailureMessage(message)
                return
            }
        } else if pending.count == 1 {
            target = .agent(pending[0])
        } else {
            target = .choosing(pending)
        }

        await closeDetailPanel(reason: .replaced)
        await openDetailPanel(.subAgent(target), on: screen)
    }

    /// The sub-agent part of ``openDetailPanel(_:on:)``: creates the
    /// controller of the detail drawn in `session`, makes it the open panel,
    /// routes the panel keys to it and opens it on `target`.
    func openSubAgentDetail(
        _ target: SubAgentDetailTarget,
        in session: TerminalModalSession
    ) async {
        let sessionRunner = sessionRunner
        let rootSessionID = sessionID
        let chatSession = chatSession
        let controller = TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: {
                await sessionRunner.subAgentSnapshotEvents(rootSessionID: rootSessionID)
            },
            transcript: { agentID in
                await chatSession.subAgentTranscript(agentID: agentID)
            },
            viewport: { session.dialogViewport() },
            present: { lines in
                session.updateDialog(TerminalDialogPresentation(prompt: lines.joined(separator: "\n")))
            },
            isCancelled: { session.isCancelled },
            onClosed: { [weak self] reason in
                await self?.closeDetailPanel(reason: reason)
            },
            modeDidChange: { [weak self] isChoosing in
                await self?.detailPanelModeDidChange(isChoosing: isChoosing, session: session)
            },
            modelTitleResolver: subAgentModelTitleResolver(),
            standardErrorIsTerminal: AgentOutput.standardErrorIsTerminal
        ))
        detailPanel = TerminalDetailPanel(content: .subAgent(controller), session: session)

        switch target {
        case let .agent(snapshot):
            await setDetailPanelMode(.detail, kind: .subAgent)
            controller.open(agentID: snapshot.id, snapshot: snapshot)
        case let .choosing(snapshots):
            await setDetailPanelMode(.list, kind: .subAgent)
            controller.open(choosing: snapshots)
        }
    }
}
