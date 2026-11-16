//
//  TerminalChatRenderCoordinator+OverviewOwnership.swift
//  ZenCODE
//
//  Ownership of the sub-agent overview rows and the fences that
//  bottom-overlay transitions put around the live rewrite regions.
//

import Foundation

extension TerminalChatRenderCoordinator {
    /// Rows the sub-agent section still owns at the current cursor position.
    /// Zero once any other output has been written after it.
    var ownedSubAgentOverviewRowCount: Int {
        guard let block = activeSubAgentOverviewBlock,
              ownsScreenReceipt(block.screenAnchor),
              block.writeSequence == emittedWriteCount else {
            return 0
        }
        return block.rows
    }

    /// Fences live rewrite regions while the status bar changes its reserved rows.
    ///
    /// The status bar writes outside this coordinator. Ordinary Chat repaints
    /// preserve the insertion point; a layout transition may scroll transcript
    /// rows, and a resize can invalidate physical anchors entirely. Keep the
    /// barrier and remove only verifiably owned tool/overview blocks before the
    /// external write; otherwise forget them append-safely. The pending tool is
    /// republished here, while the caller republishes the current overview,
    /// establishing fresh anchors within the resulting capacity.
    func beginBottomOverlayTransition(maximumInPlaceRows: Int?) {
        isBottomOverlayTransitionActive = true
        detachActiveToolBeforeBottomOverlayTransition(
            maximumInPlaceRows: maximumInPlaceRows
        )
        if activeSubAgentOverviewBlock != nil {
            clearOwnedSubAgentOverviewBeforeInterleavedOutput(
                maximumInPlaceRows: maximumInPlaceRows
            )
        }
    }

    func endBottomOverlayTransition(maximumInPlaceRows: Int? = nil) {
        isBottomOverlayTransitionActive = false
        republishToolAfterBottomOverlayTransition(
            maximumInPlaceRows: maximumInPlaceRows
        )
        renderPendingOverviewsIfIdle()
    }

    /// Gives up the slot only when geometry itself changed and the physical
    /// position or wrapping of the old block can no longer be proven safe.
    func relinquishSubAgentOverviewOwnership() {
        activeSubAgentOverviewBlock = nil
        activeSubAgentOverviewPresentation = nil
    }
}
