//
//  TerminalChat+DetailPanel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 08/11/26.
//

import Foundation

/// The panel open in the terminal above the prompt, `/subagent`'s detail or
/// `/artifacts`'s files, with the modal session it is drawn in.
/// ``TerminalChat/detailPanel`` holds it from the opening to
/// ``TerminalChat/closeDetailPanel(reason:)``: one panel at a time, so
/// opening one replaces the other. Nothing in it is saved.
struct TerminalDetailPanel {
    /// The controller that drives the panel.
    enum Content {
        case subAgent(TerminalSubAgentDetailController)
        case artifacts(TerminalArtifactsPanelController)
    }

    /// Which panel is open.
    enum Kind: Sendable, Equatable {
        case subAgent
        case artifacts

        /// The input panel's mode that goes with each routing of the panel
        /// keys to the panel; none once it is closed.
        func panelModeOverride(
            for mode: TerminalInteractiveLineReader.SubAgentDetailMode
        ) -> TerminalPanelModeOverride? {
            switch self {
            case .subAgent: TerminalChat.subAgentPanelModeOverride(for: mode)
            case .artifacts: TerminalChat.artifactsPanelModeOverride(for: mode)
            }
        }

        /// What the transcript says when a consent request closes the panel.
        var consentClosedMessage: String {
            switch self {
            case .subAgent: "Sub-agent detail closed: a tool asks for consent.\n"
            case .artifacts: "Artifacts panel closed: a tool asks for consent.\n"
            }
        }
    }

    let content: Content
    let session: TerminalModalSession

    var kind: Kind {
        switch content {
        case .subAgent: .subAgent
        case .artifacts: .artifacts
        }
    }
}

extension TerminalChat {
    /// What ``openDetailPanel(_:on:)`` opens.
    enum DetailPanelTarget {
        /// The detail of a sub-agent, or the list of the sub-agents.
        case subAgent(SubAgentDetailTarget)
        /// The files of `snapshot`, read while ``fileArtifactsRevision`` was
        /// `revision`.
        case artifacts(ChatFileArtifactSnapshot, revision: UInt64)
    }

    /// Whether a panel (`/subagent`'s or `/artifacts`') is open.
    var isDetailPanelOpen: Bool {
        detailPanel != nil
    }

    /// The screen a panel opens on: it needs the interactive panel loop (only
    /// that loop routes the keys that scroll and close it) on a primary
    /// screen that still owns the layout. `nil` otherwise.
    func detailPanelScreen() -> TerminalPrimaryScreen? {
        guard stdinIsTerminal,
              loopEventQueue != nil,
              let screen = TerminalPrimaryScreen.active,
              !screen.isAppendOnly else {
            return nil
        }
        return screen
    }

    /// Opens a panel on `screen`. The external-writer phase starts first: it
    /// retires the transient rows before the frame is drawn and holds the
    /// main transcript's output until ``closeDetailPanel(reason:)``.
    ///
    /// A close requested while that phase starts, before the panel exists (a
    /// consent request, the session ending, a menu), is not lost: the opening
    /// gives the phase back and opens nothing (``isOpeningDetailPanel``).
    func openDetailPanel(
        _ target: DetailPanelTarget,
        on screen: TerminalPrimaryScreen
    ) async {
        isOpeningDetailPanel = true
        detailPanelCloseRequestedWhileOpening = false
        defer {
            isOpeningDetailPanel = false
            detailPanelCloseRequestedWhileOpening = false
        }
        let outputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.beginExternalTerminalPrompt(maximumInPlaceRows: outputCapacity)
        guard !detailPanelCloseRequestedWhileOpening else {
            // Nothing was drawn and the panel keys were never routed to the
            // panel: only the phase started above is given back.
            await renderCoordinator.endExternalTerminalPrompt()
            return
        }

        let session = TerminalModalSession(screen: screen)
        switch target {
        case let .subAgent(target):
            await openSubAgentDetail(target, in: session)
        case let .artifacts(snapshot, revision):
            await openArtifactsPanel(snapshot, revision: revision, in: session)
        }
    }

    /// Routes the panel keys to the panel as `mode` says, shows the panel
    /// mode of `kind` that goes with it
    /// (``TerminalDetailPanel/Kind/panelModeOverride(for:)``) and redraws the
    /// input panel.
    func setDetailPanelMode(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode,
        kind: TerminalDetailPanel.Kind
    ) async {
        interactiveReader.setSubAgentDetailMode(
            mode,
            panelModeOverride: kind.panelModeOverride(for: mode)
        )
        await interactiveReader.refreshPanel()
    }

    /// Routes the panel keys and shows the panel mode of the list or of the
    /// detail, while the panel opened in `session` is still the one open.
    func detailPanelModeDidChange(
        isChoosing: Bool,
        session: TerminalModalSession
    ) async {
        guard let panel = detailPanel, panel.session === session else { return }
        await setDetailPanelMode(isChoosing ? .list : .detail, kind: panel.kind)
    }

    /// Closes the open panel, if any, and gives the terminal back: it stops
    /// the controller, closes the modal session, gives the keys back to the
    /// draft, clears the panel mode, writes why it closed for a consent
    /// request, ends the external-writer phase (which writes the output held
    /// meanwhile), and redraws the input panel.
    ///
    /// The only teardown of both panels, and safe to enter again: the panel
    /// is taken before the first suspension, so a second call (the
    /// controller's `onClosed` included) does nothing and the external-writer
    /// phase ends once per opening. A call while a panel is being opened,
    /// before it exists, cancels that opening (``openDetailPanel(_:on:)``).
    func closeDetailPanel(reason: TerminalSubAgentDetailController.CloseReason) async {
        guard let panel = detailPanel else {
            if isOpeningDetailPanel {
                detailPanelCloseRequestedWhileOpening = true
            }
            return
        }
        detailPanel = nil
        switch panel.content {
        case let .subAgent(controller):
            controller.stop()
        case let .artifacts(controller):
            controller.stop()
        }
        panel.session.close()
        await setDetailPanelMode(.closed, kind: panel.kind)
        if reason == .consent {
            // Still inside the external-writer phase: it follows the output
            // held while the panel was open.
            await writeSystemMessage(panel.kind.consentClosedMessage)
        }
        await renderCoordinator.endExternalTerminalPrompt()
        await interactiveReader.refreshPanel()
    }

    /// Closes the open panel, if any, with
    /// ``TerminalSubAgentDetailController/CloseReason/replaced`` before a menu
    /// or a line prompt takes the terminal: that modal draws its own frame
    /// and reads the keys itself, so the panel gives the screen, the keys
    /// and its external-writer phase back first. Does nothing while no
    /// panel is open.
    ///
    /// Called right before the modal opens, so a command that opens none
    /// (`/help`, say) leaves the panel open: by every interaction of
    /// ``TerminalInteractionHost`` that opens a menu or a line prompt (the
    /// menus of the shared commands, and the requests of a tool) and by the
    /// terminal's own menus and line prompts (`/feature`, the attachment
    /// picker). Consent closes the panel on its own
    /// (``TerminalSubAgentDetailController/CloseReason/consent``), and
    /// `/subagent` and `/artifacts` replace it.
    ///
    /// ``TerminalInteractionHost/requestWorkspaceAccess(_:)`` calls it only
    /// when `TerminalWorkspaceToolAccessStore` will ask, the folder not being
    /// trusted yet: a trusted folder leaves the panel open.
    func closeDetailPanelForModalInput() async {
        await closeDetailPanel(reason: .replaced)
    }

    /// Hands a key of the panel to the open panel; does nothing while none
    /// is open.
    func handleDetailPanelAction(_ action: TerminalSubAgentDetailAction) async {
        switch detailPanel?.content {
        case let .subAgent(controller)?:
            await controller.handle(action)
        case let .artifacts(controller)?:
            await controller.handle(action)
        case nil:
            return
        }
    }
}
