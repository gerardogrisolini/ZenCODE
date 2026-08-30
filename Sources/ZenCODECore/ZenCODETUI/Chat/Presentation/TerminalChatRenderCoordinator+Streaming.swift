//
//  TerminalChatRenderCoordinator+Streaming.swift
//  ZenCODE
//

import Foundation

/// Assistant and thought stream rendering plus the streaming write-coalescing machinery (leading-edge flush, trailing-edge timer, byte budget).
extension TerminalChatRenderCoordinator {
    private static let streamingFlushByteThreshold = 1_024
    private static let assistantBubblePrefix = "💬 "

    // MARK: - Streaming content

    func writeThought(_ delta: String) {
        let normalizedDelta = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            delta,
            state: &thoughtStreamingState.boldBreakState
        )
        let hasPendingAsterisk = thoughtStreamingState.boldBreakState.pendingAsterisk
        guard !normalizedDelta.isEmpty || hasPendingAsterisk else {
            return
        }
        guard thoughtStreamingState.isStreaming
                || hasPendingAsterisk
                || !normalizedDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        finishAssistantContentFormatting()
        if !thoughtStreamingState.isStreaming {
            thoughtStreamingState.isStreaming = true
            // Render the title one shade lighter than the dimmed thinking body
            // so the label stands apart from the reasoning text.
            let title = "\(TerminalStyle.Thinking.title)🤔 thinking…\(TerminalStyle.reset)"
            writeStreamingChat("\(title)\n", to: .standardError)
        }
        let renderedThought = thoughtStreamingState.markdownFormatter.consume(normalizedDelta)
        writeRenderedThought(renderedThought)
    }

    func writeAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        finishThoughtOutputIfNeeded()
        assistantStreamingState.isStreaming = true
        let normalizedDelta = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            delta,
            state: &assistantStreamingState.boldBreakState
        )
        guard !normalizedDelta.isEmpty else {
            return
        }
        var renderedContent = assistantStreamingState.markdownFormatter.consume(normalizedDelta)
        if assistantBubblePrefixPending, !renderedContent.isEmpty {
            renderedContent = Self.assistantBubblePrefix + renderedContent
            assistantBubblePrefixPending = false
        }
        if !renderedContent.isEmpty {
            writeStreamingChat(
                renderedContent,
                to: .standardOutput,
                preservesSpacing: true
            )
        }
    }

    func finishAssistantContent() {
        finishAssistantContentFormatting()
        renderPendingOverviewsIfIdle()
    }

    func finishThoughtOutput() {
        finishThoughtOutputIfNeeded()
        renderPendingOverviewsIfIdle()
    }

    func finishStreamingOutput() {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        renderPendingOverviewsIfIdle()
    }

    func finishAssistantContentFormatting() {
        guard let renderedContent = Self.finishStreamingContent(
            in: &assistantStreamingState
        ) else {
            return
        }
        var completedContent = renderedContent
        if assistantBubblePrefixPending, !completedContent.isEmpty {
            completedContent = Self.assistantBubblePrefix + completedContent
            assistantBubblePrefixPending = false
        }
        if !completedContent.isEmpty {
            writeStreamingChat(
                completedContent,
                to: .standardOutput,
                preservesSpacing: true
            )
        }
        // `consume` may already have emitted the entire assistant response,
        // leaving `finish()` empty. A streamed terminal response still needs
        // to close its physical output row before the next renderer writes.
        if standardOutputIsTerminal, currentOutputTrailingNewlineCount == 0 {
            writeStreamingChat("\n", to: .standardOutput)
        }
        assistantBubblePrefixPending = true
        flushPendingStreamingWrites()
        synchronizeStandardOutput()
    }

    func finishThoughtOutputIfNeeded() {
        guard let renderedThought = Self.finishStreamingContent(
            in: &thoughtStreamingState
        ) else {
            return
        }
        writeRenderedThought(renderedThought)
        writeStreamingChat("\n\n", to: .standardError)
        flushPendingStreamingWrites()
    }

    /// Renders thinking after Markdown so prose and structured blocks rely on
    /// the terminal's own auto-wrap rather than a hard column-based wrap. All
    /// thinking content is emitted verbatim — nothing is folded or omitted.
    private func writeRenderedThought(_ renderedThought: String) {
        let markdown = TerminalChatTextFormatting.renderThoughtMarkdown(
            renderedThought,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        if !markdown.isEmpty {
            writeStreamingChat(
                markdown,
                to: .standardError,
                preservesSpacing: true
            )
        }
    }

    private static func finishStreamingContent(
        in state: inout StreamingContentState
    ) -> String? {
        guard state.isStreaming else {
            state.boldBreakState = TerminalChatBoldBreakState()
            return nil
        }
        let flushed = TerminalChatTextFormatting.flushBoldSectionBreak(state: &state.boldBreakState)
        var renderedContent = ""
        if !flushed.isEmpty {
            renderedContent += state.markdownFormatter.consume(flushed)
        }
        renderedContent += state.markdownFormatter.finish()
        state.isStreaming = false
        return renderedContent
    }

    // MARK: - Streaming write coalescing

    /// Returns `true` when enough time has elapsed since the last streaming
    /// flush that a leading-edge flush is safe (i.e. we are not in the middle
    /// of an active burst).  The idle window mirrors ``streamingFlushDelay``
    /// so that a trailing-edge timer and a re-armed leading edge are
    /// consistent.
    private func streamingLeadingEdgeIsIdle(at now: ContinuousClock.Instant) -> Bool {
        guard let lastFlush = lastStreamingFlushInstant else {
            return true
        }
        let idleWindow = streamingFlushDelay ?? .milliseconds(32)
        return now - lastFlush >= idleWindow
    }

    func bufferStreamingWrite(_ text: String, to channel: OutputChannel) {
        guard !text.isEmpty else {
            return
        }

        // Leading-edge optimisation: when this is the first chunk of a new
        // burst (buffer was empty), no trailing-edge timer is pending, and the
        // stream has been idle long enough, flush immediately so the user sees
        // the first token without waiting for ``streamingFlushDelay``.
        // Subsequent chunks within the burst fall through to the normal
        // timer-based coalescing path.
        let wasBufferEmpty = pendingStreamingWrites.isEmpty
        let now = streamingNow()
        let canFlushLeadingEdge = streamingFlushDelay != nil
            && wasBufferEmpty
            && scheduledStreamingFlush == nil
            && streamingLeadingEdgeIsIdle(at: now)

        if pendingStreamingWrites.last?.channel == channel {
            pendingStreamingWrites[pendingStreamingWrites.count - 1].text += text
        } else {
            pendingStreamingWrites.append(PendingWrite(channel: channel, text: text))
        }
        pendingStreamingByteCount += text.utf8.count

        if pendingStreamingByteCount >= Self.streamingFlushByteThreshold {
            flushPendingStreamingWrites()
        } else if canFlushLeadingEdge {
            flushPendingStreamingWrites(cancellingScheduledFlush: false)
        } else {
            scheduleStreamingFlushIfNeeded()
        }
    }

    private func scheduleStreamingFlushIfNeeded() {
        guard scheduledStreamingFlush == nil,
              let streamingFlushDelay else {
            return
        }

        streamingFlushGeneration &+= 1
        let generation = streamingFlushGeneration
        scheduledStreamingFlush = Task(name: "ZenCODE.TUI.streaming-flush") { [weak self] in
            try? await Task.sleep(for: streamingFlushDelay)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushScheduledStreamingWrites(generation: generation)
        }
    }

    private func flushScheduledStreamingWrites(generation: UInt64) {
        guard generation == streamingFlushGeneration else {
            return
        }
        scheduledStreamingFlush = nil
        flushPendingStreamingWrites(cancellingScheduledFlush: false)
    }

    func flushPendingStreamingWrites(
        cancellingScheduledFlush: Bool = true
    ) {
        if cancellingScheduledFlush {
            scheduledStreamingFlush?.cancel()
            scheduledStreamingFlush = nil
            streamingFlushGeneration &+= 1
        }
        guard !pendingStreamingWrites.isEmpty else {
            return
        }

        let writes = pendingStreamingWrites
        pendingStreamingWrites.removeAll(keepingCapacity: true)
        pendingStreamingByteCount = 0
        for write in writes {
            emitDirect(write.text, to: write.channel)
        }
        lastStreamingFlushInstant = streamingNow()
    }
}
