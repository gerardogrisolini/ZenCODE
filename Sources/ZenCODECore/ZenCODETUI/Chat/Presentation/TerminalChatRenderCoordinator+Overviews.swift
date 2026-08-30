//
//  TerminalChatRenderCoordinator+Overviews.swift
//  ZenCODE
//

import Foundation

/// Overview arbitration (signatures, revisions, deferral, publication suspension), the sub-agent in-place section, and the FIFO mirror queue.
extension TerminalChatRenderCoordinator {
    // MARK: - Overview arbitration

    /// Advances and returns the mirroring epoch. The chat calls this at each
    /// turn boundary so undelivered notifications from the previous turn are
    /// fenced off from the new turn's reporter.
    func advanceMirrorEpoch() -> Int {
        mirrorQueue.epoch += 1
        return mirrorQueue.epoch
    }

    /// Installs or replaces the overview mirroring hook. Actor-isolated so the
    /// handler swap cannot race an in-flight mirror dispatch.
    func setOverviewMirroringHandler(
        _ handler: (@Sendable (
            _ notification: OverviewMirrorNotification,
            _ epoch: Int
        ) async -> Void)?
    ) {
        overviewMirroringHandler = handler
    }

    /// Turn-boundary barrier over the mirror queue: returns once every
    /// notification queued so far has been handed to the mirroring handler.
    /// This is a snapshot contract over the queue, not over producers: a
    /// publication whose render has not happened yet (for example a debounced
    /// task-graph observer render still inside its coalescing window) is by
    /// contract a post-turn publication and will not be mirrored for the
    /// retiring turn. Callers flush the remote channel and retire the turn
    /// reporter right after, so the turn's final message cannot be overtaken
    /// by sections the turn already rendered.
    func waitForOverviewMirrorsToDrain() async {
        guard mirrorQueue.isDraining
            || !mirrorQueue.pending.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            mirrorQueue.drainWaiters.append(continuation)
        }
    }
    private func enqueueMirrorNotification(
        _ notification: OverviewMirrorNotification
    ) {
        mirrorQueue.pending.append(
            OverviewMirrorQueueEntry(
                notification: notification,
                epoch: mirrorQueue.epoch
            )
        )
        guard !mirrorQueue.isDraining else {
            return
        }
        mirrorQueue.isDraining = true
        Task(name: "ZenCODE.TUI.overview-mirror-drain") {
            await drainMirrorNotifications()
        }
    }

    /// FIFO delivery: appends happen on this actor in render order, and this
    /// single drain task hands them to the handler one at a time. While it
    /// awaits the handler, new appends are picked up by the same loop, so the
    /// remote order always matches the local render order.
    private func drainMirrorNotifications() async {
        while !mirrorQueue.pending.isEmpty {
            let notification = mirrorQueue.pending.removeFirst()
            if let overviewMirroringHandler {
                await overviewMirroringHandler(
                    notification.notification,
                    notification.epoch
                )
            }
        }
        // No suspension between the loop exit and the flag/waiter handoff, so
        // a concurrent append cannot slip past this drain unnoticed.
        mirrorQueue.isDraining = false
        let waiters = mirrorQueue.drainWaiters
        mirrorQueue.drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Reserves a monotonically increasing publication token before snapshot
    /// work starts. Reserving eagerly lets a newer request fence an older one
    /// even when the older snapshot completes last or the active graph changes.
    func beginOverviewPublication(_ kind: OverviewKind) -> Int {
        let next = max(
            overviewState.publicationCounters[kind] ?? 0,
            overviewState.revisions[kind] ?? 0
        ) + 1
        overviewState.publicationCounters[kind] = next
        overviewState.revisions[kind] = next
        overviewState.pending.removeValue(forKey: kind)
        return next
    }

    func setOverviewPublishingSuspended(_ isSuspended: Bool) {
        overviewState.isSuspended = isSuspended
        if !isSuspended {
            renderPendingOverviewsIfIdle()
        }
    }

    @discardableResult
    func renderTaskGraphOverview(
        signature: String,
        markdown: String,
        revision: Int? = nil,
        force: Bool = false,
        rememberSignature: Bool = true
    ) -> OverviewRenderResult {
        renderOverview(
            kind: .taskGraph,
            signature: signature,
            revision: revision,
            force: force,
            rememberSignature: rememberSignature,
            content: .markdown(markdown)
        )
    }

    @discardableResult
    func renderSubAgentOverview(
        signature: String,
        text: String,
        partialResponses: [SubAgentPartialResponse] = [],
        responses: [SubAgentMarkdownResponse] = [],
        revision: Int? = nil,
        force: Bool,
        rememberSignature: Bool,
        overviewBatchID: String? = nil,
        maximumInPlaceRows: Int? = nil
    ) -> OverviewRenderResult {
        let pendingResponseTokens = responses.compactMap { response in
            overviewState.consumedResponseTokens.contains(response.token)
                ? nil
                : response.token
        }
        let publicationSignature: String
        if pendingResponseTokens.isEmpty {
            publicationSignature = signature
        } else {
            publicationSignature = ([signature] + pendingResponseTokens)
                .joined(separator: "\u{1D}")
        }
        return renderOverview(
            kind: .subAgents,
            signature: publicationSignature,
            rememberedSignature: signature,
            revision: revision,
            force: force,
            rememberSignature: rememberSignature,
            content: .subAgents(
                text: text,
                partialResponses: partialResponses,
                responses: responses,
                overviewBatchID: overviewBatchID,
                maximumInPlaceRows: maximumInPlaceRows
            )
        )
    }

    private func renderOverview(
        kind: OverviewKind,
        signature: String,
        rememberedSignature: String? = nil,
        revision: Int?,
        force: Bool,
        rememberSignature: Bool,
        content: OverviewContent
    ) -> OverviewRenderResult {
        if let revision {
            guard revision >= (overviewState.revisions[kind] ?? Int.min) else {
                return .unchanged
            }
            overviewState.revisions[kind] = revision
        }
        guard force || overviewState.signatures[kind] != signature else {
            return .unchanged
        }

        let overview = PendingOverview(
            kind: kind,
            signature: signature,
            revision: revision,
            force: force,
            rememberSignature: rememberSignature,
            rememberedSignature: rememberedSignature ?? signature,
            content: content,
            sequence: overviewState.nextSequence
        )
        overviewState.nextSequence &+= 1

        guard canRenderOverview else {
            overviewState.pending[kind] = overview
            return .deferred
        }

        overviewState.pending.removeValue(forKey: kind)
        renderOverviewNow(overview)
        return .rendered
    }

    private var canRenderOverview: Bool {
        !overviewState.isSuspended
            && !assistantStreamingState.isStreaming
            && !thoughtStreamingState.isStreaming
    }

    func renderPendingOverviewsIfIdle() {
        guard canRenderOverview, !overviewState.pending.isEmpty else {
            return
        }

        let overviews = overviewState.pending.values.sorted { $0.sequence < $1.sequence }
        overviewState.pending.removeAll(keepingCapacity: true)
        for overview in overviews {
            if let revision = overview.revision,
               revision < (overviewState.revisions[overview.kind] ?? Int.min) {
                continue
            }
            guard overview.force || overviewState.signatures[overview.kind] != overview.signature else {
                continue
            }
            renderOverviewNow(overview)
        }
    }

    private func renderOverviewNow(_ overview: PendingOverview) {
        if overview.rememberSignature {
            overviewState.signatures[overview.kind] = overview.rememberedSignature
        }
        switch overview.content {
        case let .markdown(markdown):
            renderMarkdownMessage(markdown)
            enqueueMirrorNotification(
                .taskGraph(signature: overview.signature, markdown: markdown)
            )
        case let .subAgents(
            text,
            partialResponses,
            responses,
            overviewBatchID,
            maximumInPlaceRows
        ):
            renderSubAgentOverviewContent(
                text: text,
                partialResponses: partialResponses,
                responses: responses,
                overviewBatchID: overviewBatchID,
                maximumInPlaceRows: maximumInPlaceRows
            )
        }
    }

    /// Publishes only permanent sub-agent transcript content. The live section
    /// is owned and painted by `TerminalStatusBar`; `text` is non-empty solely
    /// for the non-TTY append-only fallback.
    private func renderSubAgentOverviewContent(
        text: String,
        partialResponses: [SubAgentPartialResponse],
        responses: [SubAgentMarkdownResponse],
        overviewBatchID _: String?,
        maximumInPlaceRows _: Int?
    ) {
        let pendingResponses = responses.filter {
            !overviewState.consumedResponseTokens.contains($0.token)
        }
        let pendingPartialResponses = partialResponses.filter {
            !overviewState.consumedPartialResponseTokens.contains($0.token)
        }
        flushChatOutput()
        if !text.isEmpty {
            writeChat(text, to: .standardError)
        }
        for response in pendingPartialResponses {
            overviewState.consumedPartialResponseTokens.insert(response.token)
            enqueueMirrorNotification(.subAgentPartialResponse(response))
        }
        for response in pendingResponses {
            writeChat(response.heading, to: .standardError)
            renderMarkdownMessage(
                response.markdown,
                to: .standardError,
                linePrefix: "   "
            )
            writeChat("\n\n", to: .standardError)
            overviewState.consumedResponseTokens.insert(response.token)
            enqueueMirrorNotification(.subAgentResponse(response))
        }
    }

    func clearSubAgentOverview(revision: Int? = nil) {
        if let revision {
            guard revision >= (overviewState.revisions[.subAgents] ?? Int.min) else {
                return
            }
            overviewState.revisions[.subAgents] = revision
        }
        overviewState.pending.removeValue(forKey: .subAgents)
        overviewState.signatures.removeValue(forKey: .subAgents)
    }

    func resetOverview(_ kind: OverviewKind, revision: Int? = nil) {
        if let revision {
            guard revision >= (overviewState.revisions[kind] ?? Int.min) else {
                return
            }
            overviewState.revisions[kind] = revision
        }
        overviewState.signatures.removeValue(forKey: kind)
        overviewState.pending.removeValue(forKey: kind)
    }

    func clearDeferredOverview(_ kind: OverviewKind, revision: Int? = nil) {
        if let revision {
            guard revision >= (overviewState.revisions[kind] ?? Int.min) else {
                return
            }
            overviewState.revisions[kind] = revision
        }
        overviewState.pending.removeValue(forKey: kind)
    }

    func shouldPublishDeferredOverview(_ kind: OverviewKind) -> Bool {
        canRenderOverview && overviewState.pending[kind] != nil
    }
}
