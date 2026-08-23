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
    private static let assistantBubblePrefix = "💬 "

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
        /// Physical rows currently owned by the sub-agent overview, or `0` when
        /// no section can be rewritten in place.
        let activeSubAgentOverviewRowCount: Int
    }

    private struct PendingWrite: Sendable {
        let channel: OutputChannel
        var text: String
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
    /// Injectable monotonic clock used to measure the interval between a tool's
    /// start and completion. It is intentionally sampled only at those two
    /// lifecycle events: compact tool rows do not schedule periodic redraws.
    private let toolNow: @Sendable () -> ContinuousClock.Instant
    /// Returns the current terminal column count. Overridable in tests to
    /// simulate a deterministic resize between tool start and completion.
    private let columnWidthProvider: @Sendable () -> Int
    /// Reads the current width immediately before a destructive cursor clear.
    /// Production bypasses the short-lived width cache; injected providers keep
    /// their existing behavior unless an explicit fresh provider is supplied.
    private let freshColumnWidthProvider: @Sendable () -> Int
    private var nextWriteSequence: UInt64 = 0
    /// Counts every physical emission, whether or not writes are captured.
    /// The sub-agent overview uses it to detect that some other output was
    /// written after the section, which makes an in-place rewrite unsafe.
    private var emittedWriteCount: UInt64 = 0
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
    /// Whether the 💬 prefix still needs to be emitted at the leading edge
    /// of the next assistant response. Reset to `true` after each response
    /// finishes so every turn gets exactly one prefix.
    private var assistantBubblePrefixPending = true
    private var thoughtStreamingState: StreamingContentState
    /// A submitted prompt starts a transcript turn. The first prompt remains
    /// unadorned; every later one receives exactly one visual turn separator.
    private var hasWrittenSubmittedPrompt = false

    private var toolState = TerminalToolBlockAccounting<ActiveToolBlock>()
    private var activeSubAgentOverviewBlock: ActiveOverviewBlock?
    private var overviewState = TerminalOverviewArbitration<OverviewKind, PendingOverview>()

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
        toolNow: @Sendable @escaping () -> ContinuousClock.Instant = {
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
        self.toolNow = toolNow
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
                removesUnbalancedStrongMarkers: true,
                usesTerminalWidthForStructuredContent: false
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

    private func finishAssistantContentFormatting() {
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

    private func finishThoughtOutputIfNeeded() {
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

    // MARK: - Messages

    func writeStartupSummary(_ text: String) {
        writeInterleavedMessage { writeRawChatError(text) }
    }

    /// Writes text that already carries its own ANSI styling (bordered cards and
    /// other pre-rendered blocks) without applying the system-message color,
    /// which would otherwise override the block's own palette.
    func writePreformattedMessage(_ text: String) {
        writeInterleavedMessage { writeRawChatError(text) }
    }

    func writeSubmittedPrompt(_ prompt: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        // A new submitted prompt is a hard transcript boundary. Finalize any
        // preceding streams first so a coalesced assistant tail cannot be lost
        // behind the next turn's prompt or separator.
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        let background = TerminalStyle.Prompt.background
        let clearToEnd = "\u{1B}[K"
        let reset = TerminalStyle.reset
        let renderedLines = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                let prefix = index == 0 ? "> " : "  "
                return "\(background)\(prefix)\(line)\(clearToEnd)\(reset)"
            }
            .joined(separator: "\n")
        let separator = hasWrittenSubmittedPrompt
            ? "\(thematicTurnRule())\n"
            : ""
        writeChat("\n\(separator)\(renderedLines)\n\n", to: .standardError)
        hasWrittenSubmittedPrompt = true
        renderPendingOverviewsIfIdle()
    }

    /// A terminal-safe visual break between submitted turns. The final column
    /// stays deliberately unused because auto-wrap at exactly the terminal width
    /// is terminal-dependent; an interactive input inset is budgeted as well.
    private func thematicTurnRule() -> String {
        let contentInsetWidth = TerminalChat.displayWidth(lineInset)
        let safeWidth = max(1, columnWidthProvider() - contentInsetWidth - 1)
        let rule = String(repeating: "─", count: safeWidth)
        guard standardErrorIsTerminal else {
            return rule
        }
        return "\(TerminalStyle.Prompt.turnSeparator)\(rule)\(TerminalStyle.reset)"
    }

    func writeOutput(_ text: String, preservesSpacing: Bool = false) {
        writeInterleavedMessage { writeChat(
            text,
            to: .standardOutput,
            preservesSpacing: preservesSpacing
        ) }
    }

    func flushOutput() {
        flushChatOutput()
    }

    func writeError(_ text: String, preservesSpacing: Bool = false) {
        writeInterleavedMessage { writeChat(
            text,
            to: .standardError,
            preservesSpacing: preservesSpacing
        ) }
    }

    func writeFailureMessage(_ text: String) {
        writeInterleavedMessage { writeChat(
            TerminalChatTextFormatting.failureMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        ) }
    }

    func writeSystemMessage(_ text: String) {
        writeInterleavedMessage { writeChat(
            TerminalChatTextFormatting.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        ) }
    }

    func writeMarkdownMessage(_ markdown: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        renderMarkdownMessage(markdown)
        renderPendingOverviewsIfIdle()
    }

    func writeFileChangeSummaryMessage(_ text: String) {
        writeInterleavedMessage { writeChat(
            TerminalChatTextFormatting.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        ) }
    }

    func writeOperationalMessage(_ text: String) {
        writeInterleavedMessage { writeChat(
            TerminalChatTextFormatting.operationalMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        ) }
    }

    private func writeInterleavedMessage(_ write: () -> Void) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        write()
        renderPendingOverviewsIfIdle()
    }

    // MARK: - External terminal prompts

    /// Suspends coordinator-owned overview output before an interactive prompt
    /// writes directly to the shared terminal. The external rows move the cursor
    /// beyond any active tool block, so that block must relinquish its in-place
    /// rewrite slot; otherwise its completion would cursor-up through the prompt
    /// and erase the authorization card's footer and bottom border.
    func beginExternalTerminalPrompt() {
        overviewState.isSuspended = true
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        finishActiveToolOutputBeforeInterleavedMessage()
    }

    /// Releases the external prompt guard and publishes any overview deferred
    /// while the operator was choosing an authorization response.
    func endExternalTerminalPrompt() {
        setOverviewPublishingSuspended(false)
    }

    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        prepareForToolOutput()
        toolState.startInstants[toolCall.id] = toolNow()
        toolState.activeBlockIsSubAgentTool = DirectSubAgentRuntime
            .isSubAgentToolName(toolCall.name)
        renderToolBlock(
            toolCall,
            lifecycle: .started,
            style: toolBlockStyle(for: toolState.detailLevel),
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
        let elapsed = toolState.startInstants.removeValue(forKey: toolCall.id)
            .map { $0.duration(to: toolNow()) }
        let compactStatusDetail = TerminalChat.compactToolCompletionDetail(
            for: toolCall,
            result: result,
            elapsed: elapsed
        )

        // A completion redraws in the style of the block it owns, even if the
        // user toggled details while the tool was running. A stale completion
        // uses the current preference but never takes ownership from a newer
        // active block.
        let style = toolState.activeBlock.flatMap { block in
            block.id == toolCall.id ? block.style : nil
        } ?? toolBlockStyle(for: toolState.detailLevel)
        renderToolBlock(
            toolCall,
            lifecycle: .completed(
                result: result,
                compactStatusDetail: compactStatusDetail,
                elapsed: elapsed
            ),
            style: style,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func toggleToolDetailsOutput() {
        finishActiveToolOutputBeforeInterleavedMessage()
        toolState.detailLevel = toolState.detailLevel.next
        writeSystemMessageWithoutInterrupt(
            "Tool details: \(toolState.detailLevel.label)\n\n"
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
        var rows = toolBlockRows(
            for: toolCall,
            lifecycle: lifecycle,
            style: style,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        if !lifecycle.isCompletion, style == .detailed {
            rows = boundedStartedToolRows(
                rows,
                maximumInPlaceRows: maximumInPlaceRows
            )
        }

        switch lifecycle {
        case .started:
            toolState.activeBlock = ActiveToolBlock(
                id: toolCall.id,
                style: style,
                rows: TerminalChat.renderedTerminalRowCount(
                    for: rows.map(\.plainText),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                ),
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows
            )
        case .completed:
            let activeBlock = toolState.activeBlock
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
                // lost its earliest rows to scrollback. The same is true when
                // its content consumes the whole region: the terminating
                // newline needs one physical cursor row and scrolls the title
                // beyond the top margin. Cursor-up / erase can no longer reach
                // that title, leaving it above the completed redraw.
                //
                // A completion may be taller than the region. That does not make
                // clearing unsafe when the pending block itself is still fully
                // owned: normal output then scrolls inside the terminal's active
                // scrolling region. Bounding detailed pending blocks at start
                // keeps them rewritable and avoids leaving the hourglass copy in
                // the transcript beside a long completed result.
                let maximumReplaceableRows = min(
                    replaceableToolRowCapacity(
                        block.maximumInPlaceRows
                    ) ?? Int.max,
                    replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
                )
                return block.id == toolCall.id
                    && block.style == style
                    && standardErrorIsTerminal
                    && block.columnWidth == columnWidth
                    && block.rows <= maximumReplaceableRows
            } ?? false

            // Starts transfer the one physical rewrite slot to the newest
            // block. A completion for an older or otherwise unowned tool is
            // append-only: it must not erase the newer block. It *does*,
            // however, write transcript rows after it, so that newer block no
            // longer physically owns the cursor region and must not later
            // cursor-up through this completion.
            if ownsActiveBlock {
                toolState.activeBlock = nil
                toolState.activeBlockIsSubAgentTool = false
            } else if activeBlock != nil {
                toolState.activeBlock = nil
                toolState.activeBlockIsSubAgentTool = false
            }

            if shouldRewriteActiveBlock, let activeBlock {
                clearOwnedRows(activeBlock.rows)
            }
        }

        writeToolBlockRows(
            rows,
            for: toolCall,
            lifecycle: lifecycle,
            style: style
        )
    }

    /// Keeps a detailed pending block inside the rewriteable scrolling region.
    /// One row is reserved for the cursor after the block's terminating newline;
    /// otherwise a block that exactly fills the region scrolls its title beyond
    /// the top margin before completion can replace it.
    ///
    /// Large edit/write payloads are shown in full by the completion; while the
    /// tool is running, retain a bounded prefix plus status so that completion
    /// can replace rather than duplicate the pending block.
    private func boundedStartedToolRows(
        _ rows: [TerminalChat.DetailedToolRow],
        maximumInPlaceRows: Int?
    ) -> [TerminalChat.DetailedToolRow] {
        guard let maximumReplaceableRows = replaceableToolRowCapacity(
            maximumInPlaceRows
        ), rows.count > maximumReplaceableRows else {
            return rows
        }
        guard maximumReplaceableRows > 0 else {
            return rows.last.map { [$0] } ?? []
        }
        guard maximumReplaceableRows > 1 else {
            return rows.last.map { [$0] } ?? []
        }
        guard maximumReplaceableRows > 2 else {
            return [rows[0], rows[rows.count - 1]]
        }

        return Array(rows.prefix(maximumReplaceableRows - 2)) + [
            .text("... details shown on completion"),
            rows[rows.count - 1]
        ]
    }

    /// Converts the scrolling-region height into the number of content rows
    /// that remain cursor-reachable after `writeToolBlock` appends its newline.
    private func replaceableToolRowCapacity(
        _ maximumInPlaceRows: Int?
    ) -> Int? {
        guard let maximumInPlaceRows else {
            return nil
        }
        return maximumInPlaceRows > 0 ? maximumInPlaceRows - 1 : 0
    }

    private func toolBlockStyle(
        for detailLevel: ToolOutputDetailLevel
    ) -> ToolBlockStyle {
        detailLevel == .compact ? .compact : .detailed
    }

    private func toolBlockRows(
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle,
        contentInsetWidth: Int,
        columnWidth: Int
    ) -> [TerminalChat.DetailedToolRow] {
        switch (style, lifecycle) {
        case (.compact, .started):
            return TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "⏳",
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
            .map(TerminalChat.DetailedToolRow.text)
        case let (.compact, .completed(result, compactStatusDetail, _)):
            let hasFailedProcessExit = TerminalChat.compactLocalExecExitCode(
                for: toolCall,
                result: result
            ).map { $0 != 0 } ?? false
            return TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: result.isFailure || hasFailedProcessExit ? "⚠️" : "✅",
                statusDetail: compactStatusDetail,
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
            .map(TerminalChat.DetailedToolRow.text)
        case (.detailed, .started):
            return TerminalChat.safelyWrappedDetailedToolRows(
                TerminalChat.detailedToolCallStartedRows(for: toolCall),
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        case let (.detailed, .completed(result, _, elapsed)):
            let safeContentWidth = max(1, columnWidth - contentInsetWidth - 1)
            return TerminalChat.safelyWrappedDetailedToolRows(
                TerminalChat.detailedToolCallCompletedRows(
                    for: toolCall,
                    result: result,
                    contentWidth: safeContentWidth,
                    elapsed: elapsed
                ),
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        }
    }

    private func writeToolBlockRows(
        _ rows: [TerminalChat.DetailedToolRow],
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle
    ) {
        switch style {
        case .compact:
            writeCompactToolLines(rows.map(\.plainText), newline: lifecycle.isCompletion)
        case .detailed:
            writeToolBlock(
                rows,
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

    private func writeToolBlock(
        _ rows: [TerminalChat.DetailedToolRow],
        codeLanguage: String? = nil
    ) {
        let reset = TerminalStyle.reset
        let text = rows
            .map {
                "\(lineInset)\(TerminalChat.renderDetailedToolRow($0, codeLanguage: codeLanguage))\(reset)"
            }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
    }

    /// Removes only the rows occupied by a block this coordinator owns before
    /// redrawing it. `CSI J` would erase from the transcript into the reserved
    /// input panel.
    private func clearOwnedRows(_ rowCount: Int) {
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
        guard toolState.activeBlock != nil else {
            return
        }
        finishActiveToolOutputBeforeInterleavedMessage()
    }

    private func finishActiveToolOutputBeforeInterleavedMessage() {
        guard toolState.activeBlock != nil else {
            return
        }
        toolState.activeBlock = nil
        toolState.activeBlockIsSubAgentTool = false
        writeChat("\n", to: .standardError)
    }

    // MARK: - Overview arbitration

    /// Optional mirror invoked after an overview section is actually rendered
    /// locally, carrying the kind, the change signature, and the section text
    /// (markdown for the task graph, the plain overview text for sub-agents).
    /// Deferred overviews flow through here too, once they become renderable,
    /// so remote mirrors (e.g. Telegram) cannot miss a section that only
    /// rendered after streaming finished.
    ///
    /// Notifications are queued on this actor in render order and delivered to
    /// the handler by a single drain task, so the remote channel observes the
    /// same section order as the terminal even though delivery is asynchronous
    /// and never blocks local rendering. Use
    /// ``waitForOverviewMirrorsToDrain()`` as an end-of-turn barrier.
    var overviewMirroringHandler: (@Sendable (
        _ kind: OverviewKind,
        _ signature: String,
        _ text: String,
        _ epoch: Int
    ) async -> Void)?

    private var mirrorQueue = TerminalOverviewMirrorQueue<OverviewMirrorNotification>()

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
            _ kind: OverviewKind,
            _ signature: String,
            _ text: String,
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
        mirrorQueue.pending.append(notification)
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
                    notification.kind,
                    notification.signature,
                    notification.text,
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
            finishActiveToolOutputBeforeInterleavedMessage()
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
            && toolState.activeBlock == nil
            && !assistantStreamingState.isStreaming
            && !thoughtStreamingState.isStreaming
    }

    private func renderPendingOverviewsIfIdle() {
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
        let mirroredText: String
        switch overview.content {
        case let .markdown(markdown):
            renderMarkdownMessage(markdown)
            mirroredText = markdown
        case let .subAgents(text, responses, overviewBatchID, maximumInPlaceRows):
            renderSubAgentOverviewContent(
                text: text,
                responses: responses,
                overviewBatchID: overviewBatchID,
                maximumInPlaceRows: maximumInPlaceRows
            )
            mirroredText = text
        }
        // Only task-graph sections have a remote audience. Sub-agent snapshots
        // are terminal-only, so keeping them out of the queue avoids spawning a
        // drain task that can only call a no-op handler on every refresh tick.
        if overview.kind == .taskGraph {
            enqueueMirrorNotification(
                OverviewMirrorNotification(
                    kind: overview.kind,
                    signature: overview.signature,
                    text: mirroredText,
                    epoch: mirrorQueue.epoch
                )
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
        responses: [SubAgentMarkdownResponse],
        overviewBatchID: String?,
        maximumInPlaceRows: Int?
    ) {
        let pendingResponses = responses.filter { response in
            !overviewState.consumedResponseTokens.contains(response.token)
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

        guard pendingResponses.isEmpty else {
            // A completed response is model-authored transcript content: it is
            // printed once and must never be erased by a later refresh.
            for response in pendingResponses {
                // Keep the completed response distinct from both the live
                // status overview above and any later transcript entry.
                writeChat("\n\n", to: .standardError)
                writeChat(response.heading, to: .standardError)
                renderMarkdownMessage(response.markdown, to: .standardError)
                writeChat("\n\n", to: .standardError)
                overviewState.consumedResponseTokens.insert(response.token)
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
        guard block.rows <= maximumSafeRows else {
            return nil
        }
        return block
    }

    /// Rows the sub-agent section still owns at the current cursor position.
    /// Zero once any other output has been written after it.
    private var ownedSubAgentOverviewRowCount: Int {
        guard let block = activeSubAgentOverviewBlock,
              block.writeSequence == emittedWriteCount else {
            return 0
        }
        return block.rows
    }

    /// Gives up the in-place sub-agent overview slot when another TUI component
    /// redraws a bottom overlay. That redraw does not pass through this
    /// coordinator's write accounting, but it may reserve rows over the section
    /// that the coordinator would otherwise cursor-up and erase.
    func relinquishSubAgentOverviewOwnership() {
        activeSubAgentOverviewBlock = nil
    }

    /// Tears down the live sub-agent section when the runtime transitions to an
    /// empty snapshot. Destructive clearing is performed only while this actor
    /// still owns the exact rows; otherwise state is forgotten append-safely.
    func clearSubAgentOverview(revision: Int? = nil) {
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
              block.rows <= (block.maximumInPlaceRows ?? Int.max) else {
            return
        }
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

    // MARK: - Test and diagnostics snapshots

    func snapshot() -> Snapshot {
        let compact: (String?, Int)
        let detailed: (String?, Int)
        if let activeBlock = toolState.activeBlock {
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
            toolOutputDetailLevel: toolState.detailLevel,
            activeCompactToolCallID: compact.0,
            activeCompactToolRenderedRowCount: compact.1,
            activeDetailedToolCallID: detailed.0,
            activeDetailedToolRenderedRowCount: detailed.1,
            deferredTaskGraphOverviewRender: overviewState.pending[.taskGraph] != nil,
            deferredSubAgentOverviewRender: overviewState.pending[.subAgents] != nil,
            lastRenderedTaskGraphOverviewSignature: overviewState.signatures[.taskGraph],
            lastRenderedSubAgentOverviewSignature: overviewState.signatures[.subAgents],
            isStreamingThoughtOutput: thoughtStreamingState.isStreaming,
            activeSubAgentOverviewRowCount: ownedSubAgentOverviewRowCount
        )
    }

    func setToolOutputDetailLevel(_ level: ToolOutputDetailLevel) {
        toolState.detailLevel = level
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
        _ = writeChatMeasured(
            text,
            to: channel,
            preservesSpacing: preservesSpacing
        )
    }

    /// Writes chat text and returns exactly what reached the terminal, so a
    /// caller can measure the rows it now owns.
    @discardableResult
    private func writeChatMeasured(
        _ text: String,
        to channel: OutputChannel,
        preservesSpacing: Bool = false
    ) -> String {
        let normalizedText = preservesSpacing
            ? chatSpacingPreserved(text, for: channel)
            : chatSpacingNormalized(text, for: channel)
        recordChannelContent(after: normalizedText, for: channel)
        let renderedText = chatLineInsetApplied(to: normalizedText, for: channel)
        writeDirect(renderedText, to: channel)
        return renderedText
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

    /// True when the next character written to `channel` starts a new physical
    /// row. Unlike ``trailingNewlineCount`` this is also true at the very start
    /// of the stream, where nothing has been written yet.
    private func isAtLineStart(for channel: OutputChannel) -> Bool {
        withCursorState(for: channel) { $0.lineInset.isAtLineStart }
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

    private func currentCursorState(for channel: OutputChannel) -> CursorState {
        withCursorState(for: channel) { $0 }
    }

    private func restoreCursorState(
        _ cursorState: CursorState,
        for channel: OutputChannel
    ) {
        withCursorState(for: channel) { state in
            state = cursorState
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
        emittedWriteCount &+= 1
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
