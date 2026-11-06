//
//  ZenWindowSession+ResumeTaskGraph.swift
//  ZenApp
//
//  The startup offer of a window: the task graphs earlier sessions of the
//  project left incomplete, offered once, right after the window opens.
//

import Foundation
import ZenCODECore

/// The startup offer of a window: every new window offers the task graphs
/// that earlier sessions of the project left incomplete once, right after it
/// opened, through the flow every channel shares
/// (`ChatSessionController.offerResumableTaskGraphs(choiceHost:)`). Its menus
/// (`Open tasks from previous sessions`, `Delete old tasks`) reach the window
/// as pending requests (``pendingRequest``) and show as its choice sheets; a
/// graph the operator resumes moves into the window's session, which keeps
/// its id. The graphs of the sessions the other windows run now are left out
/// by the controller (every window is a slot of the app's one
/// `ChatSessionHost`), so a graph resumed in one window is never offered by
/// another. A later new or loaded session of the window offers nothing.
///
/// `open` asks first whether there is anything to offer
/// (``hasOfferableResumableTaskGraphs()``) and only then runs the offer as
/// the window's line (``runResumableTaskGraphOffer()``), so the session
/// starts no turn meanwhile: as for a command waiting for an answer
/// (`/models`), a prompt, typed or dictated, waits in ``queuedLines`` and
/// runs once the offer ended, any other line runs beside it or is refused,
/// and ``stop()`` refuses the menu, which ends the offer. ``close()`` refuses
/// the menu and cancels the line: the offer ends without effect. A project
/// with nothing to offer takes no line, so the window is never busy for it.
extension ZenWindowSession {
    /// Whether the project has task graphs to offer to the window's session:
    /// graphs earlier sessions left incomplete, without those of the session
    /// itself. The graphs of the sessions the other windows run now still
    /// count here (the host's live sessions are the core's to read): the
    /// offer leaves them out, and ends without asking when nothing else is
    /// left.
    func hasOfferableResumableTaskGraphs() async -> Bool {
        let sessionID = current.sessionID
        let graphs = await sessionHost.runner.resumableTaskGraphCheckpoints(workingDirectory: workspace)
        return graphs.contains { $0.sessionID != sessionID }
    }

    /// The offer, as the window's line: it asks until the operator resumes a
    /// graph, starts fresh, or cancels, or nothing is left to offer, then
    /// presents its notices (the deletions, the failed resumptions, the
    /// resumption) on the session, so they show in the transcript as every
    /// session notice, only while the window is open and still shows the
    /// incarnation that asked.
    func runResumableTaskGraphOffer() async {
        let incarnation = current
        let outcome = await incarnation.controller.offerResumableTaskGraphs()
        guard !isClosed, current.epoch == incarnation.epoch, !outcome.notices.isEmpty else { return }
        await incarnation.controller.presentSessionNotices(outcome.notices)
    }
}
