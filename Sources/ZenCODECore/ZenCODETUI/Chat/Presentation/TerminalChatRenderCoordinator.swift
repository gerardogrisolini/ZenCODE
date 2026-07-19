//
//  TerminalChatRenderCoordinator.swift
//  ZenCODE
//

import Foundation

/// Serializes every stateful chat render operation.
///
/// Async work such as task-graph and sub-agent snapshots is deliberately kept
/// outside this actor. Each entry point receives an already prepared value and
/// performs no suspension while it mutates formatter or cursor-ownership state.
actor TerminalChatRenderCoordinator {
    private static let streamingFlushByteThreshold = 1_024

    enum OverviewKind: Hashable, Sendable {
        case taskGraph
        case subAgents
    }

    enum OverviewRenderResult: Sendable, Equatable {
        case rendered
        case deferred
        case unchanged
    }

    enum OutputChannel: Sendable, Equatable {
        case standardOutput
        case standardError
    }

    /// Describes whether stdout and stderr address one physical cursor.
    /// Terminal capability alone is insufficient: two independent TTYs have
    /// separate cursor positions and therefore must not share spacing state.
    enum CursorTopology: Sendable, Equatable {
        case shared
        case separate
    }

    struct WriteEvent: Sendable, Equatable {
        let sequence: UInt64
        let channel: OutputChannel
        let text: String
    }

    /// One completed sub-agent response waiting to be presented. `token` is a
    /// stable identity for that completion, allowing the overview metadata to
    /// be refreshed without printing the same model-authored response again.
    struct SubAgentMarkdownResponse: Sendable, Equatable {
        let token: String
        let heading: String
        let markdown: String
    }

    struct Snapshot: Sendable, Equatable {
        let toolOutputDetailLevel: ToolOutputDetailLevel
        let activeCompactToolCallID: String?
        let activeCompactToolRenderedRowCount: Int
        let activeDetailedToolCallID: String?
        let activeDetailedToolRenderedRowCount: Int
        let deferredTaskGraphOverviewRender: Bool
        let deferredSubAgentOverviewRender: Bool
        let lastRenderedTaskGraphOverviewSignature: String?
        let lastRenderedSubAgentOverviewSignature: String?
        let isStreamingThoughtOutput: Bool
    }

    private enum ToolBlockStyle: Sendable, Equatable {
        case compact
        case detailed
    }

    private enum ToolBlockLifecycle {
        case started
        case completed(DirectAgentToolResult)

        var isCompletion: Bool {
            if case .completed = self {
                return true
            }
            return false
        }
    }

    /// Tracks the active tool block so it can be cleared in place on
    /// completion. `columnWidth` records the terminal width observed when
    /// `rows` was calculated: if the width changes before completion the saved
    /// row count is stale and the destructive clear is suppressed (see
    /// ``clearOwnedToolRows``).
    private struct ActiveToolBlock: Sendable, Equatable {
        let id: String
        let style: ToolBlockStyle
        let rows: Int
        let columnWidth: Int
        /// The active scroll-region capacity when this block was written.
        /// `nil` means no persistent terminal overlay was active.
        let maximumInPlaceRows: Int?
    }

    private struct PendingWrite: Sendable {
        let channel: OutputChannel
        var text: String
    }

    /// Mutable render state for one output channel. `hasContent` is used only
    /// for stdout, where markdown blocks may need a separating newline.
    private struct CursorState: Sendable {
        var spacing = TerminalChatTextFormatting.ChatSpacingState()
        var lineInset = TerminalChatTextFormatting.ChatLineInsetState()
    }

    private struct ChannelState: Sendable {
        let isTerminal: Bool
        var cursor = CursorState()
        var hasContent = false
    }

    /// Mutable formatting state for one independently streamed content flow.
    private struct StreamingContentState {
        var boldBreakState = TerminalChatBoldBreakState()
        var markdownFormatter: TerminalMarkdownStreamFormatter
        var isStreaming = false

        init(markdownFormatter: TerminalMarkdownStreamFormatter) {
            self.markdownFormatter = markdownFormatter
        }
    }

    private enum OverviewContent: Sendable {
        case markdown(String)
        case subAgents(text: String, responses: [SubAgentMarkdownResponse])
    }

    private struct PendingOverview: Sendable {
        let kind: OverviewKind
        let signature: String
        let revision: Int?
        let force: Bool
        let rememberSignature: Bool
        let rememberedSignature: String
        let content: OverviewContent
        let sequence: UInt64
    }

    private let standardOutput: FileHandle?
    private let standardError: FileHandle?
    private var standardOutputState: ChannelState
    private var standardErrorState: ChannelState
    private var sharedCursorState = CursorState()
    private let cursorTopology: CursorTopology
    private let lineInset: String
    private let capturesWrites: Bool
    private let streamingFlushDelay: Duration?
    /// Injectable monotonic clock used to decide when a leading-edge flush is
    /// safe. Tests pass a controllable closure so the idle-window check is
    /// deterministic; production uses `ContinuousClock`.
    private let streamingNow: @Sendable () -> ContinuousClock.Instant
    /// Returns the current terminal column count. Overridable in tests to
    /// simulate a deterministic resize between tool start and completion.
    private let columnWidthProvider: @Sendable () -> Int
    /// Reads the current width immediately before a destructive cursor clear.
    /// Production bypasses the short-lived width cache; injected providers keep
    /// their existing behavior unless an explicit fresh provider is supplied.
    private let freshColumnWidthProvider: @Sendable () -> Int

    private var nextWriteSequence: UInt64 = 0
    private var capturedWrites: [WriteEvent] = []
    private var pendingStreamingWrites: [PendingWrite] = []
    private var pendingStreamingByteCount = 0
    private var scheduledStreamingFlush: Task<Void, Never>?
    private var streamingFlushGeneration: UInt64 = 0
    /// Wall-clock (or injected) instant of the most recent streaming flush.
    /// Used by the leading-edge logic to suppress redundant immediate flushes
    /// while a burst is still active (trailing-edge coalescing window).
    private var lastStreamingFlushInstant: ContinuousClock.Instant?

    private var assistantStreamingState: StreamingContentState
    private var thoughtStreamingState: StreamingContentState

    private var toolOutputDetailLevel: ToolOutputDetailLevel = .compact
    private var activeToolBlock: ActiveToolBlock?
    /// True while the active tool block belongs to an `agent.*` tool call
    /// (e.g. `agent.wait`). Sub-agent overviews are allowed to interleave with
    /// such blocks so progress remains visible during long-running delegated
    /// work. Cleared whenever `activeToolBlock` becomes `nil`.
    private var activeToolBlockIsSubAgentTool = false
    private var pendingOverviews: [OverviewKind: PendingOverview] = [:]
    private var nextOverviewSequence: UInt64 = 0
    private var overviewSignatures: [OverviewKind: String] = [:]
    private var overviewRevisions: [OverviewKind: Int] = [:]
    private var overviewPublicationCounters: [OverviewKind: Int] = [:]
    private var overviewPublishingSuspended = false
    /// Completion tokens are retained independently from overview signatures:
    /// a status or tool update may legitimately republish the section, while a
    /// completed response is transient and must be emitted exactly once.
    private var consumedSubAgentResponseTokens = Set<String>()

    init(
        stdinIsTerminal: Bool,
        standardOutput: FileHandle? = AgentOutput.standardOutput,
        standardError: FileHandle? = AgentOutput.standardError,
        standardOutputIsTerminal: Bool = AgentOutput.standardOutputIsTerminal,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal,
        cursorTopology: CursorTopology? = nil,
        capturesWrites: Bool = false,
        streamingFlushDelay: Duration? = .milliseconds(32),
        streamingNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        columnWidthProvider: (@Sendable () -> Int)? = nil,
        freshColumnWidthProvider: (@Sendable () -> Int)? = nil
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputState = ChannelState(isTerminal: standardOutputIsTerminal)
        self.standardErrorState = ChannelState(isTerminal: standardErrorIsTerminal)
        self.cursorTopology = cursorTopology ?? Self.defaultCursorTopology(
            standardOutput: standardOutput,
            standardError: standardError,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        self.lineInset = stdinIsTerminal ? TerminalChatTextFormatting.chatLineInsetPrefix : ""
        self.capturesWrites = capturesWrites
        self.streamingFlushDelay = streamingFlushDelay
        self.streamingNow = streamingNow
        if let columnWidthProvider {
            self.columnWidthProvider = columnWidthProvider
            self.freshColumnWidthProvider = freshColumnWidthProvider
                ?? columnWidthProvider
        } else {
            self.columnWidthProvider = {
                TerminalChat.terminalColumnCount()
            }
            self.freshColumnWidthProvider = freshColumnWidthProvider ?? {
                TerminalChat.terminalColumnCount(forceRefresh: true)
            }
        }
        self.assistantStreamingState = StreamingContentState(
            markdownFormatter: TerminalMarkdownStreamFormatter(
                isEnabled: standardOutputIsTerminal
            )
        )
        self.thoughtStreamingState = StreamingContentState(
            markdownFormatter: TerminalMarkdownStreamFormatter(
                isEnabled: standardErrorIsTerminal,
                removesUnbalancedStrongMarkers: true
            )
        )
    }

    private static func defaultCursorTopology(
        standardOutput: FileHandle?,
        standardError: FileHandle?,
        standardOutputIsTerminal: Bool,
        standardErrorIsTerminal: Bool
    ) -> CursorTopology {
        guard standardOutputIsTerminal,
              standardErrorIsTerminal,
              let standardOutput,
              let standardError,
              TerminalWidth.sharesTerminalCursor(
                  first: standardOutput.fileDescriptor,
                  second: standardError.fileDescriptor
              ) == true else {
            return .separate
        }
        return .shared
    }

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

        interruptActiveToolForInterleavedOutputIfNeeded()
        finishAssistantContentFormatting()
        if !thoughtStreamingState.isStreaming {
            thoughtStreamingState.isStreaming = true
            let title = standardErrorIsTerminal
                ? "\u{1B}[90m🤔 Thinking:\u{1B}[0m"
                : "🤔 Thinking:"
            writeStreamingChat("\(title)\n", to: .standardError)
        }
        let renderedThought = thoughtStreamingState.markdownFormatter.consume(normalizedDelta)
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

    func writeAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        interruptActiveToolForInterleavedOutputIfNeeded()
        finishThoughtOutputIfNeeded()
        assistantStreamingState.isStreaming = true
        let normalizedDelta = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            delta,
            state: &assistantStreamingState.boldBreakState
        )
        guard !normalizedDelta.isEmpty else {
            return
        }
        let renderedContent = assistantStreamingState.markdownFormatter.consume(normalizedDelta)
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

    private func finishAssistantContentFormatting() {
        guard let renderedContent = Self.finishStreamingContent(
            in: &assistantStreamingState
        ) else {
            return
        }
        if !renderedContent.isEmpty {
            writeStreamingChat(
                renderedContent,
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
        flushPendingStreamingWrites()
        synchronizeStandardOutput()
    }

    private func finishThoughtOutputIfNeeded() {
        guard let renderedThought = Self.finishStreamingContent(
            in: &thoughtStreamingState
        ) else {
            return
        }
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
        writeStreamingChat("\n\n", to: .standardError)
        flushPendingStreamingWrites()
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

    // MARK: - Messages

    func writeStartupSummary(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeRawChatError(text)
        renderPendingOverviewsIfIdle()
    }

    func writeSubmittedPrompt(_ prompt: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        let background = "\u{1B}[48;5;236m"
        let clearToEnd = "\u{1B}[K"
        let reset = "\u{1B}[0m"
        let renderedLines = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                let prefix = index == 0 ? "> " : "  "
                return "\(background)\(prefix)\(line)\(clearToEnd)\(reset)"
            }
            .joined(separator: "\n")
        writeChat("\n\(renderedLines)\n\n", to: .standardError)
        renderPendingOverviewsIfIdle()
    }

    func writeOutput(_ text: String, preservesSpacing: Bool = false) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            text,
            to: .standardOutput,
            preservesSpacing: preservesSpacing
        )
        renderPendingOverviewsIfIdle()
    }

    func flushOutput() {
        flushChatOutput()
    }

    func writeError(_ text: String, preservesSpacing: Bool = false) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            text,
            to: .standardError,
            preservesSpacing: preservesSpacing
        )
        renderPendingOverviewsIfIdle()
    }

    func writeFailureMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            TerminalChatTextFormatting.failureMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
        renderPendingOverviewsIfIdle()
    }

    func writeSystemMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            TerminalChatTextFormatting.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
        renderPendingOverviewsIfIdle()
    }

    func writeMarkdownMessage(_ markdown: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        renderMarkdownMessage(markdown)
        renderPendingOverviewsIfIdle()
    }

    func writeFileChangeSummaryMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            TerminalChatTextFormatting.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
        renderPendingOverviewsIfIdle()
    }

    func writeOperationalMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChat(
            TerminalChatTextFormatting.operationalMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
        renderPendingOverviewsIfIdle()
    }

    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        prepareForToolOutput()
        activeToolBlockIsSubAgentTool = DirectSubAgentRuntime
            .isSubAgentToolName(toolCall.name)
        renderToolBlock(
            toolCall,
            lifecycle: .started,
            style: toolBlockStyle(for: toolOutputDetailLevel),
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()

        // A completion redraws in the style of the block it owns, even if the
        // user toggled details while the tool was running. A stale completion
        // uses the current preference but never takes ownership from a newer
        // active block.
        let style = activeToolBlock.flatMap { block in
            block.id == toolCall.id ? block.style : nil
        } ?? toolBlockStyle(for: toolOutputDetailLevel)
        renderToolBlock(
            toolCall,
            lifecycle: .completed(result),
            style: style,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func toggleToolDetailsOutput() {
        finishActiveToolOutputBeforeInterleavedMessage()
        toolOutputDetailLevel = toolOutputDetailLevel.next
        writeSystemMessageWithoutInterrupt(
            "Tool details: \(toolOutputDetailLevel.label)\n"
        )
        renderPendingOverviewsIfIdle()
    }

    func writeAccessModeChangeMessage(_ accessMode: AgentLocalExecAccessMode) {
        finishActiveToolOutputBeforeInterleavedMessage()
        switch accessMode {
        case .standard:
            writeSystemMessageWithoutInterrupt(
                "Mode: default — local.exec approvals restored.\n"
            )
        case .fullAccess:
            writeSystemMessageWithoutInterrupt(
                "Mode: full access — local.exec commands run without approval.\n"
            )
        }
        renderPendingOverviewsIfIdle()
    }

    private func prepareForToolOutput() {
        flushChatOutput()
        if standardErrorIsTerminal {
            writeChat("\n\n", to: .standardError)
        }
    }

    private func renderToolBlock(
        _ toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle,
        maximumInPlaceRows: Int?
    ) {
        let columnWidth = lifecycle.isCompletion
            ? freshColumnWidthProvider()
            : columnWidthProvider()
        let contentInsetWidth = TerminalChat.displayWidth(lineInset)
        let lines = toolBlockLines(
            for: toolCall,
            lifecycle: lifecycle,
            style: style,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )

        switch lifecycle {
        case .started:
            activeToolBlock = ActiveToolBlock(
                id: toolCall.id,
                style: style,
                rows: TerminalChat.renderedTerminalRowCount(
                    for: lines,
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                ),
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows
            )
        case .completed:
            let activeBlock = activeToolBlock
            let ownsActiveBlock = activeBlock?.id == toolCall.id
            let shouldRewriteActiveBlock = activeBlock.map { block in
                // Safety fuse: if the terminal width changed between tool start
                // and completion, the saved row count is stale. Emitting
                // cursor-up / erase sequences based on a stale count can erase
                // transcript rows or leave orphaned rows. Instead, degrade
                // fail-safe: skip the destructive clear and append the
                // completed block.
                //
                // A block that exceeded the scrolling region has already
                // lost its earliest rows to scrollback. Cursor-up is clamped
                // at the top of the terminal (not the scrolling margin), so
                // clearing its original row count would descend through the
                // reserved input/status overlay. Append its completion instead.
                let maximumSafeRows = min(
                    block.maximumInPlaceRows ?? Int.max,
                    maximumInPlaceRows ?? Int.max
                )
                return block.id == toolCall.id
                    && block.style == style
                    && standardErrorIsTerminal
                    && block.columnWidth == columnWidth
                    && block.rows <= maximumSafeRows
            } ?? false

            // Starts transfer the one physical rewrite slot to the newest
            // block. A completion for an older or otherwise unowned tool is
            // append-only: it must not erase or relinquish the newer block.
            if ownsActiveBlock {
                activeToolBlock = nil
                activeToolBlockIsSubAgentTool = false
            }

            if shouldRewriteActiveBlock, let activeBlock {
                clearOwnedToolRows(activeBlock.rows)
            }
        }

        writeToolBlockLines(
            lines,
            for: toolCall,
            lifecycle: lifecycle,
            style: style
        )
    }

    private func toolBlockStyle(
        for detailLevel: ToolOutputDetailLevel
    ) -> ToolBlockStyle {
        detailLevel == .compact ? .compact : .detailed
    }

    private func toolBlockLines(
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle,
        contentInsetWidth: Int,
        columnWidth: Int
    ) -> [String] {
        switch (style, lifecycle) {
        case (.compact, .started):
            return TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "⏳",
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        case let (.compact, .completed(result)):
            return TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: result.isFailure ? "⚠️" : "✅",
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        case (.detailed, .started):
            return TerminalChat.safelyWrappedDetailedToolLines(
                TerminalChat.detailedToolCallStartedLines(for: toolCall),
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        case let (.detailed, .completed(result)):
            return TerminalChat.safelyWrappedDetailedToolLines(
                TerminalChat.detailedToolCallCompletedLines(
                    for: toolCall,
                    result: result
                ),
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        }
    }

    private func writeToolBlockLines(
        _ lines: [String],
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle
    ) {
        switch style {
        case .compact:
            writeCompactToolLines(lines, newline: lifecycle.isCompletion)
        case .detailed:
            writeToolBlock(
                lines,
                codeLanguage: TerminalChat.codeLanguageHint(for: toolCall)
            )
            if lifecycle.isCompletion {
                writeChat("\n", to: .standardError)
            }
        }
    }

    private func writeCompactToolLines(
        _ lines: [String],
        newline: Bool = false,
        terminator: String = "\n"
    ) {
        let text = TerminalChat.compactToolTerminalText(
            lines,
            lineInset: lineInset,
            newline: newline,
            terminator: terminator
        )
        writeRawChatError(text)
    }

    private func writeToolBlock(_ lines: [String], codeLanguage: String? = nil) {
        let reset = "\u{1B}[0m"
        let text = lines
            .map {
                "\(lineInset)\(TerminalChat.renderDetailedToolLine($0, codeLanguage: codeLanguage))\(reset)"
            }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
    }

    /// Removes only the rows occupied by the pending tool before redrawing it.
    /// `CSI J` would erase from the transcript into the reserved input panel.
    private func clearOwnedToolRows(_ rowCount: Int) {
        let count = max(1, rowCount)
        var sequence = "\u{1B}[\(count)A\r"

        for row in 0..<count {
            sequence += "\u{1B}[2K"
            if row < count - 1 {
                sequence += "\u{1B}[1B\r"
            }
        }
        if count > 1 {
            sequence += "\u{1B}[\(count - 1)A\r"
        }

        writeDirect(sequence, to: .standardError)
    }

    private func interruptActiveToolForInterleavedOutputIfNeeded() {
        guard activeToolBlock != nil else {
            return
        }
        finishActiveToolOutputBeforeInterleavedMessage()
    }

    private func finishActiveToolOutputBeforeInterleavedMessage() {
        guard activeToolBlock != nil else {
            return
        }
        activeToolBlock = nil
        activeToolBlockIsSubAgentTool = false
        writeChat("\n", to: .standardError)
    }

    // MARK: - Overview arbitration

    /// Reserves a monotonically increasing publication token before snapshot
    /// work starts. Reserving eagerly lets a newer request fence an older one
    /// even when the older snapshot completes last or the active graph changes.
    func beginOverviewPublication(_ kind: OverviewKind) -> Int {
        let next = max(
            overviewPublicationCounters[kind] ?? 0,
            overviewRevisions[kind] ?? 0
        ) + 1
        overviewPublicationCounters[kind] = next
        overviewRevisions[kind] = next
        pendingOverviews.removeValue(forKey: kind)
        return next
    }

    func setOverviewPublishingSuspended(_ isSuspended: Bool) {
        overviewPublishingSuspended = isSuspended
        if !isSuspended {
            renderPendingOverviewsIfIdle()
        }
    }

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

    func renderSubAgentOverview(
        signature: String,
        text: String,
        responses: [SubAgentMarkdownResponse] = [],
        force: Bool,
        rememberSignature: Bool
    ) -> OverviewRenderResult {
        let pendingResponseTokens = responses.compactMap { response in
            consumedSubAgentResponseTokens.contains(response.token)
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
            revision: nil,
            force: force,
            rememberSignature: rememberSignature,
            content: .subAgents(text: text, responses: responses)
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
            guard revision >= (overviewRevisions[kind] ?? Int.min) else {
                return .unchanged
            }
            overviewRevisions[kind] = revision
        }
        guard force || overviewSignatures[kind] != signature else {
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
            sequence: nextOverviewSequence
        )
        nextOverviewSequence &+= 1

        // A sub-agent overview may interleave with an active `agent.*` tool
        // block (e.g. agent.wait) so progress stays visible while the blocking
        // call is in flight. The interrupt is performed ONLY when it is the
        // sole remaining obstacle to rendering: publication must not be
        // suspended and no assistant/thought streaming may be active. This
        // preserves the deferred path and tool-block row ownership when
        // publication is suspended or while streaming is in progress.
        if kind == .subAgents,
           activeToolBlock != nil,
           activeToolBlockIsSubAgentTool,
           !overviewPublishingSuspended,
           !assistantStreamingState.isStreaming,
           !thoughtStreamingState.isStreaming {
            finishActiveToolOutputBeforeInterleavedMessage()
        }

        guard canRenderOverview else {
            pendingOverviews[kind] = overview
            return .deferred
        }

        pendingOverviews.removeValue(forKey: kind)
        renderOverviewNow(overview)
        return .rendered
    }

    private var canRenderOverview: Bool {
        !overviewPublishingSuspended
            && activeToolBlock == nil
            && !assistantStreamingState.isStreaming
            && !thoughtStreamingState.isStreaming
    }

    private func renderPendingOverviewsIfIdle() {
        guard canRenderOverview, !pendingOverviews.isEmpty else {
            return
        }

        let overviews = pendingOverviews.values.sorted { $0.sequence < $1.sequence }
        pendingOverviews.removeAll(keepingCapacity: true)
        for overview in overviews {
            if let revision = overview.revision,
               revision < (overviewRevisions[overview.kind] ?? Int.min) {
                continue
            }
            guard overview.force || overviewSignatures[overview.kind] != overview.signature else {
                continue
            }
            renderOverviewNow(overview)
        }
    }

    private func renderOverviewNow(_ overview: PendingOverview) {
        if overview.rememberSignature {
            overviewSignatures[overview.kind] = overview.rememberedSignature
        }
        switch overview.content {
        case let .markdown(markdown):
            renderMarkdownMessage(markdown)
        case let .subAgents(text, responses):
            writeChat(text, to: .standardError)
            for response in responses
            where !consumedSubAgentResponseTokens.contains(response.token) {
                writeChat(response.heading, to: .standardError)
                renderMarkdownMessage(response.markdown, to: .standardError)
                consumedSubAgentResponseTokens.insert(response.token)
            }
        }
    }

    func resetOverview(_ kind: OverviewKind, revision: Int? = nil) {
        if let revision {
            guard revision >= (overviewRevisions[kind] ?? Int.min) else {
                return
            }
            overviewRevisions[kind] = revision
        }
        overviewSignatures.removeValue(forKey: kind)
        pendingOverviews.removeValue(forKey: kind)
    }

    func clearDeferredOverview(_ kind: OverviewKind, revision: Int? = nil) {
        if let revision {
            guard revision >= (overviewRevisions[kind] ?? Int.min) else {
                return
            }
            overviewRevisions[kind] = revision
        }
        pendingOverviews.removeValue(forKey: kind)
    }

    func shouldPublishDeferredOverview(_ kind: OverviewKind) -> Bool {
        canRenderOverview && pendingOverviews[kind] != nil
    }

    // MARK: - Test and diagnostics snapshots

    func snapshot() -> Snapshot {
        let compact: (String?, Int)
        let detailed: (String?, Int)
        if let activeBlock = activeToolBlock {
            switch activeBlock.style {
            case .compact:
                compact = (activeBlock.id, activeBlock.rows)
                detailed = (nil, 0)
            case .detailed:
                compact = (nil, 0)
                detailed = (activeBlock.id, activeBlock.rows)
            }
        } else {
            compact = (nil, 0)
            detailed = (nil, 0)
        }
        return Snapshot(
            toolOutputDetailLevel: toolOutputDetailLevel,
            activeCompactToolCallID: compact.0,
            activeCompactToolRenderedRowCount: compact.1,
            activeDetailedToolCallID: detailed.0,
            activeDetailedToolRenderedRowCount: detailed.1,
            deferredTaskGraphOverviewRender: pendingOverviews[.taskGraph] != nil,
            deferredSubAgentOverviewRender: pendingOverviews[.subAgents] != nil,
            lastRenderedTaskGraphOverviewSignature: overviewSignatures[.taskGraph],
            lastRenderedSubAgentOverviewSignature: overviewSignatures[.subAgents],
            isStreamingThoughtOutput: thoughtStreamingState.isStreaming
        )
    }

    func setToolOutputDetailLevel(_ level: ToolOutputDetailLevel) {
        toolOutputDetailLevel = level
    }

    func capturedWriteEvents() -> [WriteEvent] {
        capturedWrites
    }

    func waitForScheduledStreamingFlush() async {
        let task = scheduledStreamingFlush
        await task?.value
    }

    // MARK: - Low-level output

    private func renderMarkdownMessage(
        _ markdown: String,
        to channel: OutputChannel = .standardOutput
    ) {
        guard !markdown.isEmpty else {
            return
        }
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: channelIsTerminal(channel)
        )
        let rendered = formatter.consume(markdown) + formatter.finish()
        guard !rendered.isEmpty else {
            return
        }
        let hasPriorContent = channel == .standardOutput
            ? hasStandardOutputContent
            : true
        if hasPriorContent, trailingNewlineCount(for: channel) == 0 {
            writeChat("\n", to: channel, preservesSpacing: true)
        }
        writeChat(rendered, to: channel, preservesSpacing: true)
        if trailingNewlineCount(for: channel) == 0 {
            writeChat("\n", to: channel)
        }
        flushChatOutput()
    }

    private func writeSystemMessageWithoutInterrupt(_ text: String) {
        writeChat(
            TerminalChatTextFormatting.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
    }

    private func writeChat(
        _ text: String,
        to channel: OutputChannel,
        preservesSpacing: Bool = false
    ) {
        let normalizedText = preservesSpacing
            ? chatSpacingPreserved(text, for: channel)
            : chatSpacingNormalized(text, for: channel)
        recordChannelContent(after: normalizedText, for: channel)
        writeDirect(
            chatLineInsetApplied(to: normalizedText, for: channel),
            to: channel
        )
    }

    private func writeStreamingChat(
        _ text: String,
        to channel: OutputChannel,
        preservesSpacing: Bool = false
    ) {
        let normalizedText = preservesSpacing
            ? chatSpacingPreserved(text, for: channel)
            : chatSpacingNormalized(text, for: channel)
        recordChannelContent(after: normalizedText, for: channel)
        bufferStreamingWrite(
            chatLineInsetApplied(to: normalizedText, for: channel),
            to: channel
        )
    }

    private func flushChatOutput() {
        flushPendingStreamingWrites()
        synchronizeStandardOutput()
    }

    private func synchronizeStandardOutput() {
        guard standardOutputIsTerminal else {
            return
        }
        standardOutput?.synchronizeFile()
    }

    private func writeRawChatError(_ text: String) {
        let normalizedText = chatSpacingNormalized(text, for: .standardError)
        recordChannelContent(after: normalizedText, for: .standardError)
        updateChatLineInsetState(after: normalizedText, for: .standardError)
        writeDirect(normalizedText, to: .standardError)
    }

    private var standardOutputIsTerminal: Bool {
        channelIsTerminal(.standardOutput)
    }

    private var standardErrorIsTerminal: Bool {
        channelIsTerminal(.standardError)
    }

    private var hasStandardOutputContent: Bool {
        withChannelState(for: .standardOutput) { $0.hasContent }
    }

    private var usesSharedTerminalCursor: Bool {
        cursorTopology == .shared
            && standardOutputIsTerminal
            && standardErrorIsTerminal
    }

    /// The trailing line state at the terminal currently receiving chat output.
    /// When stdout and stderr share a terminal, a completed tool block written
    /// to stderr determines the real cursor position before an overview is
    /// written to stdout.
    private var currentOutputTrailingNewlineCount: Int {
        trailingNewlineCount(for: .standardOutput)
    }

    private func chatSpacingNormalized(
        _ text: String,
        for channel: OutputChannel
    ) -> String {
        withCursorState(for: channel) { state in
            TerminalChatTextFormatting.chatSpacingNormalized(
                text,
                state: &state.spacing
            )
        }
    }

    private func chatSpacingPreserved(
        _ text: String,
        for channel: OutputChannel
    ) -> String {
        withCursorState(for: channel) { state in
            TerminalChatTextFormatting.updateChatSpacingState(
                afterPreserving: text,
                state: &state.spacing
            )
        }
        return text
    }

    private func channelIsTerminal(_ channel: OutputChannel) -> Bool {
        withChannelState(for: channel) { $0.isTerminal }
    }

    private func trailingNewlineCount(for channel: OutputChannel) -> Int {
        withCursorState(for: channel) { $0.spacing.trailingNewlineCount }
    }

    private func withChannelState<Result>(
        for channel: OutputChannel,
        _ operation: (inout ChannelState) -> Result
    ) -> Result {
        switch channel {
        case .standardOutput:
            return operation(&standardOutputState)
        case .standardError:
            return operation(&standardErrorState)
        }
    }

    private func withCursorState<Result>(
        for channel: OutputChannel,
        _ operation: (inout CursorState) -> Result
    ) -> Result {
        if usesSharedTerminalCursor {
            return operation(&sharedCursorState)
        }
        return withChannelState(for: channel) { state in
            operation(&state.cursor)
        }
    }

    private func recordChannelContent(after text: String, for channel: OutputChannel) {
        let info = TerminalANSIText.trailingVisibleNewlineInfo(text)
        guard info.hasVisible else {
            return
        }
        guard channel == .standardOutput else {
            return
        }
        withChannelState(for: channel) { state in
            state.hasContent = true
        }
    }

    private func chatLineInsetApplied(
        to text: String,
        for channel: OutputChannel
    ) -> String {
        withCursorState(for: channel) { state in
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: text,
                prefix: lineInset,
                state: &state.lineInset
            )
        }
    }

    private func updateChatLineInsetState(
        after text: String,
        for channel: OutputChannel
    ) {
        withCursorState(for: channel) { state in
            TerminalChatTextFormatting.updateChatLineInsetState(
                after: text,
                state: &state.lineInset
            )
        }
    }

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

    private func bufferStreamingWrite(_ text: String, to channel: OutputChannel) {
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
        scheduledStreamingFlush = Task { [weak self] in
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

    private func flushPendingStreamingWrites(
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

    private func writeDirect(_ text: String, to channel: OutputChannel) {
        flushPendingStreamingWrites()
        emitDirect(text, to: channel)
    }

    private func emitDirect(_ text: String, to channel: OutputChannel) {
        guard !text.isEmpty else {
            return
        }
        if capturesWrites {
            capturedWrites.append(
                WriteEvent(
                    sequence: nextWriteSequence,
                    channel: channel,
                    text: text
                )
            )
            nextWriteSequence += 1
        }
        switch channel {
        case .standardOutput:
            standardOutput?.writeString(text)
        case .standardError:
            standardError?.writeString(text)
        }
    }
}
