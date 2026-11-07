//
//  TerminalChat+SubAgentDetail.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation
import ToolCore

/// The `/subagent` detail open in the terminal: the controller that drives
/// the panel and the modal session the panel is drawn in.
/// ``TerminalChat/subAgentDetail`` holds it from the opening to
/// ``TerminalChat/closeSubAgentDetail(reason:)``. Nothing in it is saved.
struct TerminalSubAgentDetail {
    let controller: TerminalSubAgentDetailController
    let session: TerminalModalSession
}

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

    /// Whether the `/subagent` detail is open.
    var isSubAgentDetailOpen: Bool {
        subAgentDetail != nil
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
    /// replaces a detail already open.
    ///
    /// The detail needs the interactive panel loop (only that loop routes the
    /// keys that scroll and close it) on a primary screen that still owns the
    /// layout; otherwise, and when no sub-agent is in progress, it writes why
    /// and opens nothing. A failed match leaves an open detail as it is.
    ///
    /// The agent list owns every key of the panel. An agent's detail takes
    /// only the keys that scroll it and `Esc`, which closes it: the prompt
    /// keeps the other keys, so prompts and `@` mentions are typed and sent
    /// while it stays open, and a command goes on with it open unless it
    /// opens a menu or a line prompt
    /// (``closeSubAgentDetailForModalInput()``).
    func handleSubAgentCommand(_ command: String) async {
        guard stdinIsTerminal,
              loopEventQueue != nil,
              let screen = TerminalPrimaryScreen.active,
              !screen.isAppendOnly else {
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

        await closeSubAgentDetail(reason: .replaced)
        await openSubAgentDetail(target, on: screen)
    }

    /// Opens the detail on `screen`. The external-writer phase starts first:
    /// it retires the transient rows before the frame is drawn and holds the
    /// main transcript's output until ``closeSubAgentDetail(reason:)``.
    ///
    /// A close requested while that phase starts, before the detail exists
    /// (a consent request, the session ending, a menu), is not lost: the
    /// opening gives the phase back and opens nothing
    /// (``isOpeningSubAgentDetail``).
    func openSubAgentDetail(
        _ target: SubAgentDetailTarget,
        on screen: TerminalPrimaryScreen
    ) async {
        isOpeningSubAgentDetail = true
        subAgentDetailCloseRequestedWhileOpening = false
        defer {
            isOpeningSubAgentDetail = false
            subAgentDetailCloseRequestedWhileOpening = false
        }
        let outputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.beginExternalTerminalPrompt(maximumInPlaceRows: outputCapacity)
        guard !subAgentDetailCloseRequestedWhileOpening else {
            // Nothing was drawn and the panel keys were never routed to the
            // detail: only the phase started above is given back.
            await renderCoordinator.endExternalTerminalPrompt()
            return
        }

        let session = TerminalModalSession(screen: screen)
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
                await self?.closeSubAgentDetail(reason: reason)
            },
            modeDidChange: { [weak self] isChoosing in
                await self?.subAgentDetailModeDidChange(isChoosing: isChoosing, session: session)
            },
            modelTitleResolver: subAgentModelTitleResolver(),
            standardErrorIsTerminal: AgentOutput.standardErrorIsTerminal
        ))
        subAgentDetail = TerminalSubAgentDetail(controller: controller, session: session)

        switch target {
        case let .agent(snapshot):
            await setSubAgentDetailPanelMode(.detail)
            controller.open(agentID: snapshot.id, snapshot: snapshot)
        case let .choosing(snapshots):
            await setSubAgentDetailPanelMode(.list)
            controller.open(choosing: snapshots)
        }
    }

    /// Routes the panel keys to the detail as `mode` says, shows the panel
    /// mode that goes with it
    /// (``subAgentPanelModeOverride(for:)``) and redraws the panel.
    private func setSubAgentDetailPanelMode(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) async {
        interactiveReader.setSubAgentDetailMode(
            mode,
            panelModeOverride: Self.subAgentPanelModeOverride(for: mode)
        )
        await interactiveReader.refreshPanel()
    }

    /// Routes the panel keys and shows the panel mode of the list or of the
    /// detail, while the detail opened in `session` is still the one open.
    func subAgentDetailModeDidChange(
        isChoosing: Bool,
        session: TerminalModalSession
    ) async {
        guard subAgentDetail?.session === session else { return }
        await setSubAgentDetailPanelMode(isChoosing ? .list : .detail)
    }

    /// Closes the open detail, if any, and gives the terminal back: it stops
    /// the controller, closes the modal session, gives the keys back to the
    /// draft, clears the panel mode, writes why it closed for a consent
    /// request, ends the external-writer phase (which writes the output held
    /// meanwhile), and redraws the panel.
    ///
    /// The only teardown of the detail, and safe to enter again: the detail
    /// is taken before the first suspension, so a second call (the
    /// controller's ``TerminalSubAgentDetailController/Environment/onClosed``
    /// included) does nothing and the external-writer phase ends once per
    /// opening. A call while a detail is being opened, before it exists,
    /// cancels that opening (``openSubAgentDetail(_:on:)``).
    func closeSubAgentDetail(reason: TerminalSubAgentDetailController.CloseReason) async {
        guard let detail = subAgentDetail else {
            if isOpeningSubAgentDetail {
                subAgentDetailCloseRequestedWhileOpening = true
            }
            return
        }
        subAgentDetail = nil
        detail.controller.stop()
        detail.session.close()
        await setSubAgentDetailPanelMode(.closed)
        if reason == .consent {
            // Still inside the external-writer phase: it follows the output
            // held while the detail was open.
            await writeSystemMessage("Sub-agent detail closed: a tool asks for consent.\n")
        }
        await renderCoordinator.endExternalTerminalPrompt()
        await interactiveReader.refreshPanel()
    }

    /// Closes the open detail, if any, with
    /// ``TerminalSubAgentDetailController/CloseReason/replaced`` before a menu
    /// or a line prompt takes the terminal: that modal draws its own frame
    /// and reads the keys itself, so the detail gives the screen, the keys
    /// and its external-writer phase back first. Does nothing while no
    /// detail is open.
    ///
    /// Called right before the modal opens, so a command that opens none
    /// (`/help`, say) leaves the detail open: by every interaction of
    /// ``TerminalInteractionHost`` that opens a menu or a line prompt (the
    /// menus of the shared commands, and the requests of a tool) and by the
    /// terminal's own menus and line prompts (`/feature`, the attachment
    /// picker). Consent closes the detail on its own
    /// (``TerminalSubAgentDetailController/CloseReason/consent``) and
    /// `/subagent` replaces it.
    ///
    /// ``TerminalInteractionHost/requestWorkspaceAccess(_:)`` calls it only
    /// when `TerminalWorkspaceToolAccessStore` will ask, the folder not being
    /// trusted yet: a trusted folder leaves the detail open.
    func closeSubAgentDetailForModalInput() async {
        await closeSubAgentDetail(reason: .replaced)
    }

    /// Hands a key of the panel to the open detail; does nothing while none
    /// is open.
    func handleSubAgentDetailAction(_ action: TerminalSubAgentDetailAction) async {
        await subAgentDetail?.controller.handle(action)
    }
}
