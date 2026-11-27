//
//  TerminalChat+DetailPanel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 08/11/26.
//

import Foundation
import ZenCODERuntime

/// The panel open in the terminal, `/subagent`'s detail or `/artifacts`'s
/// files, with the modal session it is drawn in. It is modal and takes the
/// whole screen: while it is open the bottom layout (the shared-chat dock,
/// the input panel and the status bar) is hidden
/// (``TerminalStatusBar/setFooterHidden(_:)``) and every key but end-of-input
/// belongs to it. ``TerminalChat/detailPanel`` holds it from the opening to
/// ``TerminalChat/closeDetailPanel(reason:keepsFooterHidden:)``: one panel at
/// a time, so opening one replaces the other. Nothing in it is saved.
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

        /// The panel mode that goes with each routing of the panel keys to
        /// the panel; none once it is closed. Its help is the one table of
        /// the keys of each mode: the panel draws it in its bottom border
        /// (``TerminalSubAgentDetailPanel/BorderStatus/help``), and the input
        /// panel, hidden behind the panel, keeps it as its mode.
        /// `detailReturnsToList` tells that `Esc` in the detail goes back to
        /// the list, because the detail was opened from it (an agent of
        /// `/subagent`, a file of `/artifacts`).
        func panelModeOverride(
            for mode: TerminalInteractiveLineReader.SubAgentDetailMode,
            detailReturnsToList: Bool = false
        ) -> TerminalPanelModeOverride? {
            switch self {
            case .subAgent:
                TerminalChat.subAgentPanelModeOverride(for: mode, detailReturnsToList: detailReturnsToList)
            case .artifacts:
                TerminalChat.artifactsPanelModeOverride(for: mode, detailReturnsToList: detailReturnsToList)
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

    /// Whether the panel opened on its list, so that `Esc` in a detail goes
    /// back to it instead of closing the panel.
    @ChatSessionActor
    var detailReturnsToList: Bool {
        switch content {
        case let .subAgent(controller): controller.returnsToList
        case let .artifacts(controller): controller.returnsToList
        }
    }

    /// Draws the panel again, for a change outside its own data: the
    /// shared-chat badge of its bottom border.
    @ChatSessionActor
    func redraw() {
        switch content {
        case let .subAgent(controller): controller.redraw()
        case let .artifacts(controller): controller.redraw()
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
    /// main transcript's output until
    /// ``closeDetailPanel(reason:keepsFooterHidden:)``. Then the bottom layout
    /// is hidden (``TerminalStatusBar/setFooterHidden(_:)``), before the
    /// modal session exists, so that the panel's first frame already takes
    /// the rows the layout gave back.
    ///
    /// The scrolling capacity is read before both, while the layout is still
    /// drawn: it describes the region in which the external-writer phase
    /// retires the transient rows. Hiding the layout moves no transcript row,
    /// so a capacity read after it would grow by the layout's rows and could
    /// let that phase rewrite in place a block that had already scrolled past
    /// the top of the smaller region. When this panel replaces another one
    /// the layout is still hidden, and the capacity is the one of the region
    /// the previous panel left, where its held output was just written.
    ///
    /// A close requested while the opening suspends, before the panel exists
    /// (a consent request, the session ending, a menu), is not lost: the
    /// opening shows the layout again, gives the phase back and opens nothing
    /// (``isOpeningDetailPanel``).
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
        await statusBar.setFooterHidden(true)
        guard !detailPanelCloseRequestedWhileOpening else {
            // Nothing was drawn and the panel keys were never routed to the
            // panel: only the layout and the phase taken above are given back.
            await statusBar.setFooterHidden(false)
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

    /// Routes the panel keys to the panel as `mode` says, records the panel
    /// mode of `kind` that goes with it
    /// (``TerminalDetailPanel/Kind/panelModeOverride(for:detailReturnsToList:)``)
    /// and redraws the input panel, which only updates its state while the
    /// panel hides it.
    func setDetailPanelMode(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode,
        kind: TerminalDetailPanel.Kind,
        detailReturnsToList: Bool = false
    ) async {
        interactiveReader.setSubAgentDetailMode(
            mode,
            panelModeOverride: kind.panelModeOverride(for: mode, detailReturnsToList: detailReturnsToList)
        )
        await interactiveReader.refreshPanel()
    }

    /// Routes the panel keys and shows the panel mode of the list or of the
    /// detail, while the panel opened in `session` is still the one open. The
    /// detail of a panel that opened on its list shows that `Esc` goes back to
    /// it.
    func detailPanelModeDidChange(
        isChoosing: Bool,
        session: TerminalModalSession
    ) async {
        guard let panel = detailPanel, panel.session === session else { return }
        await setDetailPanelMode(
            isChoosing ? .list : .detail,
            kind: panel.kind,
            detailReturnsToList: panel.detailReturnsToList
        )
    }

    /// Closes the open panel, if any, and gives the terminal back: it stops
    /// the controller, closes the modal session, gives the keys back to the
    /// draft, clears the panel mode, shows the bottom layout again (the
    /// dock, the input panel with the draft as it was left, and the status
    /// bar, drawn whole for the geometry of the moment), writes why it closed
    /// for a consent request, ends the external-writer phase (which writes
    /// the output held meanwhile), and redraws the input panel.
    ///
    /// `keepsFooterHidden` leaves the bottom layout hidden, for the one
    /// caller that opens another panel at once (`/subagent` and `/artifacts`
    /// replacing the open panel): the layout does not flash between the two
    /// frames, and ``openDetailPanel(_:on:)`` shows it again itself if that
    /// opening is cancelled. Every other close shows it.
    ///
    /// The only teardown of both panels, and safe to enter again: the panel
    /// is taken before the first suspension, so a second call (the
    /// controller's `onClosed` included) does nothing and the external-writer
    /// phase ends once per opening. A call while a panel is being opened,
    /// before it exists, cancels that opening (``openDetailPanel(_:on:)``).
    func closeDetailPanel(
        reason: TerminalSubAgentDetailController.CloseReason,
        keepsFooterHidden: Bool = false
    ) async {
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
        // The input panel loses the panel's mode while it is still hidden, so
        // the layout comes back in one frame, already without it.
        await setDetailPanelMode(.closed, kind: panel.kind)
        if !keepsFooterHidden {
            await statusBar.setFooterHidden(false)
        }
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
    /// above the bottom layout and reads the keys itself, so the panel gives
    /// the screen, the bottom layout, the keys and its external-writer phase
    /// back first. Does nothing while no panel is open.
    ///
    /// Called right before the modal opens, so that only an interaction that
    /// really opens one closes the panel: every interaction of
    /// ``TerminalInteractionHost`` that opens a menu or a line prompt (the
    /// requests of a tool, and the menus of the shared commands) and the
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

    /// The shared-chat messages not read yet, for the badge of the panel's
    /// bottom border: those of the reading buffer of the panel loop that
    /// runs (``sharedChatUnreadCountReader``), none without it.
    var sharedChatUnreadCount: Int {
        sharedChatUnreadCountReader?() ?? 0
    }

    /// The shared-chat messages not read yet may have changed: the open
    /// panel, if any, draws its bottom border again, so its badge follows
    /// them while no new data of its own arrives.
    func sharedChatUnreadCountDidChange() {
        detailPanel?.redraw()
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
