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

        // A sub-agent overview may interleave with an active `agent.*` tool
        // block (e.g. agent.wait) so progress stays visible while the blocking
        // call is in flight. The interrupt is performed ONLY when it is the
        // sole remaining obstacle to rendering: publication must not be
        // suspended and no assistant/thought streaming may be active. This
        // preserves the deferred path and tool-block row ownership when
        // publication is suspended or while streaming is in progress.
        if kind == .subAgents,
           toolState.activeBlock != nil,
           toolState.activeBlockIsSubAgentTool,
           !overviewState.isSuspended,
           !assistantStreamingState.isStreaming,
           !thoughtStreamingState.isStreaming {
            let maximumInPlaceRows: Int?
            if case let .subAgents(_, _, _, _, rows) = content {
                maximumInPlaceRows = rows
            } else {
                maximumInPlaceRows = nil
            }
            replaceActiveSubAgentToolWithOverview(
                maximumInPlaceRows: maximumInPlaceRows
            )
        }

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
            && !isBottomOverlayTransitionActive
            && toolState.activeBlock == nil
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

    /// Draws the sub-agent section, replacing the previously drawn section in
    /// place whenever this coordinator still owns the rows it occupies.
    ///
    /// Ownership is lost as soon as any other output is emitted after the
    /// section, the terminal is resized, or the section grew past the scrolling
    /// region: in those cases the update is appended, exactly as before.
    private func renderSubAgentOverviewContent(
        text: String,
        partialResponses: [SubAgentPartialResponse],
        responses: [SubAgentMarkdownResponse],
        overviewBatchID: String?,
        maximumInPlaceRows: Int?
    ) {
        let pendingResponses = responses.filter { response in
            !overviewState.consumedResponseTokens.contains(response.token)
        }
        let pendingPartialResponses = partialResponses.filter { response in
            !overviewState.consumedPartialResponseTokens.contains(response.token)
        }
        // Any buffered streaming bytes must reach the terminal before the
        // ownership check, otherwise they would be emitted between the check
        // and the erase and shift the rows this section believes it owns.
        flushChatOutput()
        let columnWidth = freshColumnWidthProvider()
        let reusableBlock = reusableSubAgentOverviewBlock(
            anchorID: overviewBatchID,
            columnWidth: columnWidth,
            maximumInPlaceRows: maximumInPlaceRows
        )

        // Restoring the spacing state recorded before the previous section was
        // drawn keeps the replacement byte-identical to a first publication:
        // the leading blank line normalizer would otherwise be suppressed after
        // the cursor moved back up.
        if let reusableBlock {
            moveCursorAboveBottomOverlayGap(reusableBlock.cursorGapRows)
            clearOwnedRows(reusableBlock.rows)
            restoreCursorState(reusableBlock.cursorStateBeforeRender, for: .standardError)
        }

        // Only a section that starts on a fresh row owns whole physical rows.
        // Starting mid-row would share its first row with earlier transcript
        // content that a later erase must not touch.
        let startsAtLineStart = isAtLineStart(for: .standardError)
        let cursorStateBeforeRender = currentCursorState(for: .standardError)
        let renderedText = writeChatMeasured(text, to: .standardError)
        activeSubAgentOverviewBlock = nil

        // These model-authored blocks are already visible as 💬 rows inside the
        // overview. Notify remote mirrors only after the local render succeeds,
        // and consume their stable identities so in-place refreshes cannot resend
        // the same answer.
        for response in pendingPartialResponses {
            overviewState.consumedPartialResponseTokens.insert(response.token)
            enqueueMirrorNotification(.subAgentPartialResponse(response))
        }

        guard pendingResponses.isEmpty else {
            // A completed response is model-authored transcript content: it is
            // printed once and must never be erased by a later refresh.
            for response in pendingResponses {
                // Place the response immediately under its agent metadata.
                // The rendered Markdown is nested as presentation, rather
                // than source indentation, so lists and other blocks retain
                // their normal Markdown semantics.
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
            return
        }

        // A missing identity is not an identity. Callers that cannot establish
        // the logical wave must remain append-only rather than accidentally
        // treating all nil anchors as one reusable region.
        guard standardErrorIsTerminal,
              overviewBatchID != nil,
              startsAtLineStart,
              let rows = ownedRowCount(of: renderedText, columnWidth: columnWidth),
              rows <= (maximumInPlaceRows ?? Int.max) else {
            return
        }
        activeSubAgentOverviewBlock = ActiveOverviewBlock(
            rows: rows,
            cursorGapRows: 0,
            columnWidth: columnWidth,
            maximumInPlaceRows: maximumInPlaceRows,
            cursorStateBeforeRender: cursorStateBeforeRender,
            writeSequence: emittedWriteCount
        )
    }

    /// Number of physical rows a rendered block occupies, or `nil` when the
    /// count cannot be trusted for a destructive in-place rewrite.
    ///
    /// The block must end on a line boundary (so the cursor rests on the row
    /// after it) and no row may reach the final column, where auto-wrap is
    /// deferred and terminal-dependent.
    private func ownedRowCount(
        of renderedText: String,
        columnWidth: Int
    ) -> Int? {
        guard !renderedText.isEmpty, columnWidth > 1 else {
            return nil
        }
        var rows = TerminalANSIText.stripANSI(renderedText)
            .components(separatedBy: "\n")
        guard rows.count > 1, rows.removeLast().isEmpty else {
            return nil
        }
        guard rows.allSatisfy({ TerminalChat.displayWidth($0) < columnWidth }) else {
            return nil
        }
        return rows.count
    }

    /// Returns the previously drawn section when it can still be safely erased.
    /// A new non-nil batch takes over the same live overview slot: requiring the
    /// old and new batch identifiers to match would leave the old section above
    /// the new one even though no intervening output invalidated its ownership.
    private func reusableSubAgentOverviewBlock(
        anchorID: String?,
        columnWidth: Int,
        maximumInPlaceRows: Int?
    ) -> ActiveOverviewBlock? {
        guard standardErrorIsTerminal,
              anchorID != nil,
              let block = activeSubAgentOverviewBlock,
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth else {
            return nil
        }
        // A section taller than the scrolling region has already lost its
        // earliest rows to scrollback, so cursor-up would descend through the
        // reserved overlay instead of its own rows.
        let maximumSafeRows = min(
            block.maximumInPlaceRows ?? Int.max,
            maximumInPlaceRows ?? Int.max
        )
        guard block.rows + block.cursorGapRows <= maximumSafeRows else {
            return nil
        }
        return block
    }

    /// Rows the sub-agent section still owns at the current cursor position.
    /// Zero once any other output has been written after it.
    var ownedSubAgentOverviewRowCount: Int {
        guard let block = activeSubAgentOverviewBlock,
              block.writeSequence == emittedWriteCount else {
            return 0
        }
        return block.rows
    }

    /// Fences live rewrite regions while the status bar changes its reserved rows.
    ///
    /// The status bar writes outside this coordinator and may place the cursor at
    /// the new scroll boundary even when the visible overlay height is unchanged.
    /// Capacity deltas therefore cannot prove that a relative cursor anchor is
    /// still valid. Remove verifiably owned tool and overview blocks before that
    /// external write; otherwise forget them append-safely. The pending tool is
    /// republished here after the transition, while the caller republishes the
    /// current overview snapshot, establishing fresh physical anchors.
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
    }

    private func moveCursorAboveBottomOverlayGap(_ rowCount: Int) {
        guard rowCount > 0 else { return }
        writeDirect("\u{1B}[\(rowCount)A\r", to: .standardError)
    }

    /// Removes a still-owned transient overview before a coordinator tool
    /// lifecycle block is written. Starts and completions both replace the live
    /// overview in the one shared rewrite slot; otherwise every subsequent
    /// coordinator call would strand the prior section in the transcript.
    func clearOwnedSubAgentOverviewBeforeInterleavedOutput(
        maximumInPlaceRows: Int?
    ) {
        flushChatOutput()
        // The lifecycle block removes the live overview from the terminal's
        // current presentation even when the snapshot itself has not changed.
        // Forget its signature so the publication immediately following an
        // tool start/completion can redraw that same snapshot. Otherwise
        // `agent.wait` keeps only its tool row visible until agent state changes
        // (or the wait completes), because every periodic refresh is incorrectly
        // deduplicated against a section that is no longer on screen.
        overviewState.signatures.removeValue(forKey: .subAgents)
        guard let block = activeSubAgentOverviewBlock else { return }
        activeSubAgentOverviewBlock = nil
        let columnWidth = freshColumnWidthProvider()
        let maximumSafeRows = min(
            block.maximumInPlaceRows ?? Int.max,
            maximumInPlaceRows ?? Int.max
        )
        guard standardErrorIsTerminal,
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows + block.cursorGapRows <= maximumSafeRows else {
            return
        }
        moveCursorAboveBottomOverlayGap(block.cursorGapRows)
        clearOwnedRows(block.rows)
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
    }

    /// Tears down the live sub-agent section when the runtime transitions to an
    /// empty snapshot. Destructive clearing is performed only while this actor
    /// still owns the exact rows and they still fit the current scrolling
    /// region; otherwise state is forgotten append-safely.
    func clearSubAgentOverview(
        revision: Int? = nil,
        maximumInPlaceRows: Int? = nil
    ) {
        if let revision {
            guard revision >= (overviewState.revisions[.subAgents] ?? Int.min) else {
                return
            }
            overviewState.revisions[.subAgents] = revision
        }
        overviewState.pending.removeValue(forKey: .subAgents)
        overviewState.signatures.removeValue(forKey: .subAgents)

        flushChatOutput()
        guard let block = activeSubAgentOverviewBlock else { return }
        activeSubAgentOverviewBlock = nil
        let columnWidth = freshColumnWidthProvider()
        guard standardErrorIsTerminal,
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows + block.cursorGapRows <= min(
                  block.maximumInPlaceRows ?? Int.max,
                  maximumInPlaceRows ?? Int.max
              ) else {
            return
        }
        moveCursorAboveBottomOverlayGap(block.cursorGapRows)
        clearOwnedRows(block.rows)
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
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
