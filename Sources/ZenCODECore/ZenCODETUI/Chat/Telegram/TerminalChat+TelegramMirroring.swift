//
//  TerminalChat+TelegramMirroring.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    // MARK: - Root response mirroring

    /// Aggregates one visible root response delta for the linked chat.
    ///
    /// Deltas are buffered by the turn reporter and published as a single
    /// message at the next tool boundary; nothing is sent while the response is
    /// still streaming.
    func appendTelegramRootResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        telegramRootResponseBlockHasContent = true
        guard !telegramRootResponseBlockIsSuppressed,
              let reporter = activeTelegramProgressReporter else {
            return
        }
        await reporter.appendAgentResponseDelta(delta)
    }

    /// Publishes the aggregated root response at a tool-call boundary.
    ///
    /// The boundary proves the response complete: the model stopped writing and
    /// started a tool. The overview barrier runs first so sub-agent and Task
    /// sections already rendered enter the ordered channel ahead of this
    /// response instead of being overtaken by it.
    func publishTelegramRootResponseAtToolBoundary() async {
        let wasSuppressed = telegramRootResponseBlockIsSuppressed
        telegramRootResponseBlockHasContent = false
        telegramRootResponseBlockIsSuppressed = false
        guard let reporter = activeTelegramProgressReporter else {
            return
        }
        guard !wasSuppressed else {
            await reporter.discardPendingAgentResponse()
            return
        }
        guard await reporter.hasPendingAgentResponse else {
            return
        }
        await renderCoordinator.waitForOverviewMirrorsToDrain()
        guard let current = activeTelegramProgressReporter,
              current === reporter else {
            // Telegram was turned off while the barrier was draining; the
            // buffered text belongs to a channel that no longer exists.
            return
        }
        if await current.publishPendingAgentResponseAtBoundary() {
            telegramDidPublishIntermediateRootResponse = true
        }
    }

    /// Returns the text to mirror as the turn's final response.
    ///
    /// A turn's response text accumulates every assistant block it produced,
    /// including the intermediate responses already mirrored at their tool
    /// boundaries. Mirroring it verbatim would repeat them, so once such a
    /// response was published the trailing block aggregated since the last
    /// boundary — the final response itself — is mirrored instead.
    func telegramMirroredFinalResponseText(fallback: String) async -> String {
        guard telegramDidPublishIntermediateRootResponse,
              let reporter = activeTelegramProgressReporter else {
            return fallback
        }
        let trailing = await reporter.pendingAgentResponseText()
        return trailing.isEmpty ? fallback : trailing
    }

    /// Marks the streaming root response as unmirrorable, when one is in flight.
    /// Cross-extension visibility: lifecycle reconciliation calls this when a
    /// reporter must be retired mid-response.
    func suppressTelegramRootResponseBlockIfStreaming() {
        guard telegramRootResponseBlockHasContent else {
            return
        }
        telegramRootResponseBlockIsSuppressed = true
    }

    /// Cross-extension visibility: turn lifecycle begins/resets the mirrored
    /// response block state.
    func resetTelegramRootResponseBlock() {
        telegramRootResponseBlockHasContent = false
        telegramRootResponseBlockIsSuppressed = false
        telegramDidPublishIntermediateRootResponse = false
    }
}
