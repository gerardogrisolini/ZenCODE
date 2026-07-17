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

    struct WriteEvent: Sendable, Equatable {
        let sequence: UInt64
        let channel: OutputChannel
        let text: String
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

    private enum ActiveToolBlock: Sendable, Equatable {
        case compact(id: String, rows: Int)
        case detailed(id: String, rows: Int)
    }

    private struct PendingWrite: Sendable {
        let channel: OutputChannel
        var text: String
    }

    private enum OverviewContent: Sendable {
        case markdown(String)
        case text(String)
    }

    private struct PendingOverview: Sendable {
        let kind: OverviewKind
        let signature: String
        let revision: Int?
        let force: Bool
        let rememberSignature: Bool
        let content: OverviewContent
        let sequence: UInt64
    }

    private let standardOutput: FileHandle?
    private let standardError: FileHandle?
    private let standardOutputIsTerminal: Bool
    private let standardErrorIsTerminal: Bool
    private let lineInset: String
    private let capturesWrites: Bool
    private let streamingFlushDelay: Duration?

    private var nextWriteSequence: UInt64 = 0
    private var capturedWrites: [WriteEvent] = []
    private var pendingStreamingWrites: [PendingWrite] = []
    private var pendingStreamingByteCount = 0
    private var scheduledStreamingFlush: Task<Void, Never>?
    private var streamingFlushGeneration: UInt64 = 0

    private var assistantBoldBreakState = TerminalChatBoldBreakState()
    private var thoughtBoldBreakState = TerminalChatBoldBreakState()
    private var isAtStartOfChatLine = true
    private var trailingChatNewlineCount = 0
    private var assistantMarkdownFormatter: TerminalMarkdownStreamFormatter
    private var thoughtMarkdownFormatter: TerminalMarkdownStreamFormatter
    private var isStreamingAssistantOutput = false
    private var isStreamingThoughtOutput = false
    private var hasStandardOutputContent = false
    private var standardOutputTrailingNewlineCount = 0
    private var standardErrorTrailingNewlineCount = 0

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

    init(
        stdinIsTerminal: Bool,
        standardOutput: FileHandle? = AgentOutput.standardOutput,
        standardError: FileHandle? = AgentOutput.standardError,
        standardOutputIsTerminal: Bool = AgentOutput.standardOutputIsTerminal,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal,
        capturesWrites: Bool = false,
        streamingFlushDelay: Duration? = .milliseconds(32)
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputIsTerminal = standardOutputIsTerminal
        self.standardErrorIsTerminal = standardErrorIsTerminal
        self.lineInset = stdinIsTerminal ? TerminalChat.chatLineInsetPrefix : ""
        self.capturesWrites = capturesWrites
        self.streamingFlushDelay = streamingFlushDelay
        self.assistantMarkdownFormatter = TerminalMarkdownStreamFormatter(
            isEnabled: standardOutputIsTerminal
        )
        self.thoughtMarkdownFormatter = TerminalMarkdownStreamFormatter(
            isEnabled: standardErrorIsTerminal,
            removesUnbalancedStrongMarkers: true
        )
    }

    // MARK: - Streaming content

    func writeThought(_ delta: String) {
        let normalizedDelta = TerminalChat.normalizedBoldSectionBreak(
            delta,
            state: &thoughtBoldBreakState
        )
        guard !normalizedDelta.isEmpty else {
            return
        }
        guard isStreamingThoughtOutput
                || !normalizedDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        interruptActiveToolForInterleavedOutputIfNeeded()
        finishAssistantContentFormatting()
        if !isStreamingThoughtOutput {
            isStreamingThoughtOutput = true
            let title = standardErrorIsTerminal
                ? "\u{1B}[90m🤔 Thinking:\u{1B}[0m"
                : "🤔 Thinking:"
            writeStreamingChatError("\(title)\n")
        }
        let renderedThought = thoughtMarkdownFormatter.consume(normalizedDelta)
        let markdown = TerminalChat.renderThoughtMarkdown(
            renderedThought,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        if !markdown.isEmpty {
            writeStreamingChatError(markdown, preservesSpacing: true)
        }
    }

    func writeAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        interruptActiveToolForInterleavedOutputIfNeeded()
        finishThoughtOutputIfNeeded()
        isStreamingAssistantOutput = true
        let normalizedDelta = TerminalChat.normalizedBoldSectionBreak(
            delta,
            state: &assistantBoldBreakState
        )
        guard !normalizedDelta.isEmpty else {
            return
        }
        let renderedContent = assistantMarkdownFormatter.consume(normalizedDelta)
        if !renderedContent.isEmpty {
            writeStreamingChatOutput(renderedContent, preservesSpacing: true)
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
        guard isStreamingAssistantOutput else {
            assistantBoldBreakState = TerminalChatBoldBreakState()
            return
        }
        let flushed = TerminalChat.flushBoldSectionBreak(state: &assistantBoldBreakState)
        var renderedContent = ""
        if !flushed.isEmpty {
            renderedContent += assistantMarkdownFormatter.consume(flushed)
        }
        renderedContent += assistantMarkdownFormatter.finish()
        if !renderedContent.isEmpty {
            writeStreamingChatOutput(renderedContent, preservesSpacing: true)
            if standardOutputIsTerminal, trailingChatNewlineCount == 0 {
                writeStreamingChatOutput("\n")
            }
        }
        flushPendingStreamingWrites()
        synchronizeStandardOutput()
        isStreamingAssistantOutput = false
    }

    private func finishThoughtOutputIfNeeded() {
        guard isStreamingThoughtOutput else {
            thoughtBoldBreakState = TerminalChatBoldBreakState()
            return
        }
        let flushed = TerminalChat.flushBoldSectionBreak(state: &thoughtBoldBreakState)
        var renderedThought = ""
        if !flushed.isEmpty {
            renderedThought += thoughtMarkdownFormatter.consume(flushed)
        }
        renderedThought += thoughtMarkdownFormatter.finish()
        let markdown = TerminalChat.renderThoughtMarkdown(
            renderedThought,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        if !markdown.isEmpty {
            writeStreamingChatError(markdown, preservesSpacing: true)
        }
        writeStreamingChatError("\n\n")
        flushPendingStreamingWrites()
        isStreamingThoughtOutput = false
    }

    // MARK: - Messages

    func writeStartupSummary(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeRawChatError(text)
        isAtStartOfChatLine = text.hasSuffix("\n")
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
        writeChatError("\n\(renderedLines)\n\n")
        renderPendingOverviewsIfIdle()
    }

    func writeOutput(_ text: String, preservesSpacing: Bool = false) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChatOutput(text, preservesSpacing: preservesSpacing)
        renderPendingOverviewsIfIdle()
    }

    func flushOutput() {
        flushChatOutput()
    }

    func writeError(_ text: String, preservesSpacing: Bool = false) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChatError(text, preservesSpacing: preservesSpacing)
        renderPendingOverviewsIfIdle()
    }

    func writeFailureMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChatError(
            TerminalChat.failureMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            )
        )
        renderPendingOverviewsIfIdle()
    }

    func writeSystemMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChatError(
            TerminalChat.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            )
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
        writeChatError(
            TerminalChat.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            )
        )
        renderPendingOverviewsIfIdle()
    }

    func writeOperationalMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        writeChatError(
            TerminalChat.operationalMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            )
        )
        renderPendingOverviewsIfIdle()
    }

    // MARK: - Tool blocks

    func writeToolCallStarted(_ toolCall: DirectAgentToolCall) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        prepareForToolOutput()
        activeToolBlockIsSubAgentTool = DirectSubAgentRuntime
            .isSubAgentToolName(toolCall.name)
        if toolOutputDetailLevel == .compact {
            writeCompactToolCallStarted(toolCall)
        } else {
            writeDetailedToolCallStarted(toolCall)
        }
    }

    func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()

        let activeCompactID: String?
        if case let .compact(id, _) = activeToolBlock {
            activeCompactID = id
        } else {
            activeCompactID = nil
        }
        if toolOutputDetailLevel == .compact || activeCompactID == toolCall.id {
            writeCompactToolCallCompleted(toolCall, result: result)
        } else {
            writeDetailedToolCallCompleted(toolCall, result: result)
        }
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
            writeChatError("\n\n")
        }
    }

    private func writeDetailedToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let lines = TerminalChat.detailedToolCallStartedLines(for: toolCall)
        activeToolBlock = .detailed(
            id: toolCall.id,
            rows: TerminalChat.renderedTerminalRowCount(
                for: lines,
                contentInsetWidth: lineInset.count
            )
        )
        writeToolBlock(lines, codeLanguage: TerminalChat.codeLanguageHint(for: toolCall))
    }

    private func writeDetailedToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )
        let rewriteRowCount: Int
        let shouldRewriteActiveBlock: Bool
        if case let .detailed(id, rows) = activeToolBlock {
            rewriteRowCount = rows
            shouldRewriteActiveBlock = id == toolCall.id && standardErrorIsTerminal
        } else {
            rewriteRowCount = 0
            shouldRewriteActiveBlock = false
        }
        activeToolBlock = nil
        activeToolBlockIsSubAgentTool = false

        if shouldRewriteActiveBlock {
            clearOwnedToolRows(rewriteRowCount)
        }
        writeToolBlock(lines, codeLanguage: TerminalChat.codeLanguageHint(for: toolCall))
        writeChatError("\n")
    }

    private func writeCompactToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "⏳",
            contentInsetWidth: lineInset.count
        )
        activeToolBlock = .compact(
            id: toolCall.id,
            rows: TerminalChat.renderedTerminalRowCount(
                for: lines,
                contentInsetWidth: lineInset.count
            )
        )
        writeCompactToolLines(lines, newline: false)
    }

    private func writeCompactToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        let icon = result.isFailure ? "⚠️" : "✅"
        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: icon,
            contentInsetWidth: lineInset.count
        )
        let rewriteRowCount: Int
        let shouldRewriteActiveLine: Bool
        if case let .compact(id, rows) = activeToolBlock {
            rewriteRowCount = rows
            shouldRewriteActiveLine = id == toolCall.id && standardErrorIsTerminal
        } else {
            rewriteRowCount = 0
            shouldRewriteActiveLine = false
        }
        activeToolBlock = nil
        activeToolBlockIsSubAgentTool = false

        if shouldRewriteActiveLine {
            clearOwnedToolRows(rewriteRowCount)
        }
        writeCompactToolLines(lines, newline: true)
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
        isAtStartOfChatLine = terminator.hasSuffix("\n")
    }

    private func writeToolBlock(_ lines: [String], codeLanguage: String? = nil) {
        let reset = "\u{1B}[0m"
        let text = lines
            .map {
                "\(lineInset)\(TerminalChat.renderDetailedToolLine($0, codeLanguage: codeLanguage))\(reset)"
            }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
        isAtStartOfChatLine = true
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
        writeChatError("\n")
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
        force: Bool,
        rememberSignature: Bool
    ) -> OverviewRenderResult {
        renderOverview(
            kind: .subAgents,
            signature: signature,
            revision: nil,
            force: force,
            rememberSignature: rememberSignature,
            content: .text(text)
        )
    }

    private func renderOverview(
        kind: OverviewKind,
        signature: String,
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
           !isStreamingAssistantOutput,
           !isStreamingThoughtOutput {
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
            && !isStreamingAssistantOutput
            && !isStreamingThoughtOutput
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
            overviewSignatures[overview.kind] = overview.signature
        }
        switch overview.content {
        case let .markdown(markdown):
            renderMarkdownMessage(markdown)
        case let .text(text):
            writeChatError(text)
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
        switch activeToolBlock {
        case let .compact(id, rows):
            compact = (id, rows)
            detailed = (nil, 0)
        case let .detailed(id, rows):
            compact = (nil, 0)
            detailed = (id, rows)
        case nil:
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
            isStreamingThoughtOutput: isStreamingThoughtOutput
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

    private func renderMarkdownMessage(_ markdown: String) {
        guard !markdown.isEmpty else {
            return
        }
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: standardOutputIsTerminal
        )
        let rendered = formatter.consume(markdown) + formatter.finish()
        guard !rendered.isEmpty else {
            return
        }
        if hasStandardOutputContent, standardOutputTrailingNewlineCount == 0 {
            writeChatOutput("\n", preservesSpacing: true)
        }
        writeChatOutput(rendered, preservesSpacing: true)
        if standardOutputTrailingNewlineCount == 0 {
            writeChatOutput("\n")
        }
        flushChatOutput()
    }

    private func writeSystemMessageWithoutInterrupt(_ text: String) {
        writeChatError(
            TerminalChat.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            )
        )
    }

    private func writeChatOutput(_ text: String, preservesSpacing: Bool = false) {
        let normalizedText = preservesSpacing
            ? chatOutputSpacingPreserved(text)
            : chatOutputSpacingNormalized(text)
        updateStandardOutputState(after: normalizedText)
        writeDirect(chatLineInsetApplied(to: normalizedText), to: .standardOutput)
    }

    private func writeStreamingChatOutput(
        _ text: String,
        preservesSpacing: Bool = false
    ) {
        let normalizedText = preservesSpacing
            ? chatOutputSpacingPreserved(text)
            : chatOutputSpacingNormalized(text)
        updateStandardOutputState(after: normalizedText)
        bufferStreamingWrite(
            chatLineInsetApplied(to: normalizedText),
            to: .standardOutput
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

    private func writeChatError(_ text: String, preservesSpacing: Bool = false) {
        let normalizedText = preservesSpacing
            ? chatErrorSpacingPreserved(text)
            : chatErrorSpacingNormalized(text)
        updateStandardErrorState(after: normalizedText)
        writeDirect(chatLineInsetApplied(to: normalizedText), to: .standardError)
    }

    private func writeStreamingChatError(
        _ text: String,
        preservesSpacing: Bool = false
    ) {
        let normalizedText = preservesSpacing
            ? chatErrorSpacingPreserved(text)
            : chatErrorSpacingNormalized(text)
        updateStandardErrorState(after: normalizedText)
        bufferStreamingWrite(
            chatLineInsetApplied(to: normalizedText),
            to: .standardError
        )
    }

    private func writeRawChatError(_ text: String) {
        let normalizedText = chatErrorSpacingNormalized(text)
        updateStandardErrorState(after: normalizedText)
        writeDirect(normalizedText, to: .standardError)
    }

    private var usesSharedTerminalSpacing: Bool {
        standardOutputIsTerminal && standardErrorIsTerminal
    }

    private func chatOutputSpacingNormalized(_ text: String) -> String {
        guard !usesSharedTerminalSpacing else {
            return sharedChatSpacingNormalized(text)
        }
        return TerminalChat.chatSpacingNormalized(
            text,
            trailingNewlineCount: &standardOutputTrailingNewlineCount
        )
    }

    private func chatErrorSpacingNormalized(_ text: String) -> String {
        guard !usesSharedTerminalSpacing else {
            return sharedChatSpacingNormalized(text)
        }
        return TerminalChat.chatSpacingNormalized(
            text,
            trailingNewlineCount: &standardErrorTrailingNewlineCount
        )
    }

    private func sharedChatSpacingNormalized(_ text: String) -> String {
        TerminalChat.chatSpacingNormalized(
            text,
            trailingNewlineCount: &trailingChatNewlineCount
        )
    }

    private func chatOutputSpacingPreserved(_ text: String) -> String {
        updateSharedTerminalSpacingIfNeeded(after: text)
        return text
    }

    private func chatErrorSpacingPreserved(_ text: String) -> String {
        updateSharedTerminalSpacingIfNeeded(after: text)
        return text
    }

    private func updateSharedTerminalSpacingIfNeeded(after text: String) {
        guard usesSharedTerminalSpacing else {
            return
        }
        TerminalChat.updateTrailingNewlineCount(
            afterPreserving: text,
            trailingNewlineCount: &trailingChatNewlineCount
        )
    }

    private func chatLineInsetApplied(to text: String) -> String {
        TerminalChat.chatLineInsetApplied(
            to: text,
            prefix: lineInset,
            isAtLineStart: &isAtStartOfChatLine
        )
    }

    private func updateStandardOutputState(after text: String) {
        let info = TerminalANSIText.trailingVisibleNewlineInfo(text)
        guard info.hasVisible else {
            return
        }
        hasStandardOutputContent = true
        standardOutputTrailingNewlineCount = info.trailingNewlines
    }

    private func updateStandardErrorState(after text: String) {
        let info = TerminalANSIText.trailingVisibleNewlineInfo(text)
        guard info.hasVisible else {
            return
        }
        standardErrorTrailingNewlineCount = info.trailingNewlines
    }

    private func bufferStreamingWrite(_ text: String, to channel: OutputChannel) {
        guard !text.isEmpty else {
            return
        }

        if pendingStreamingWrites.last?.channel == channel {
            pendingStreamingWrites[pendingStreamingWrites.count - 1].text += text
        } else {
            pendingStreamingWrites.append(PendingWrite(channel: channel, text: text))
        }
        pendingStreamingByteCount += text.utf8.count

        if pendingStreamingByteCount >= Self.streamingFlushByteThreshold {
            flushPendingStreamingWrites()
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
