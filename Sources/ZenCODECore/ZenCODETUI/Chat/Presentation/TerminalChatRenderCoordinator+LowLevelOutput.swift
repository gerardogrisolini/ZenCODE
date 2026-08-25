//
//  TerminalChatRenderCoordinator+LowLevelOutput.swift
//  ZenCODE
//

import Foundation

/// Low-level channel primitives: measured writes, spacing/line-inset state, shared-cursor topology, and direct terminal emission.
extension TerminalChatRenderCoordinator {
    // MARK: - Low-level output

    func renderMarkdownMessage(
        _ markdown: String,
        to channel: OutputChannel = .standardOutput,
        linePrefix: String = ""
    ) {
        guard !markdown.isEmpty else {
            return
        }
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: channelIsTerminal(channel),
            presentationPrefixWidth: TerminalANSIText.visibleWidth(linePrefix)
        )
        let rendered = Self.indentedMarkdown(
            formatter.consume(markdown) + formatter.finish(),
            with: linePrefix
        )
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

    /// Applies presentation-only nesting after Markdown has been rendered, so
    /// prefixes cannot change the source Markdown's block structure.
    static func indentedMarkdown(_ text: String, with linePrefix: String) -> String {
        guard !linePrefix.isEmpty, !text.isEmpty else {
            return text
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A fenced code block closes with a newline. The normal output writer
        // supplies its own terminator, so retaining this final element would
        // create an extra unindented terminal row after nested Markdown.
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { linePrefix + $0 }.joined(separator: "\n")
    }

    func writeSystemMessageWithoutInterrupt(_ text: String) {
        writeChat(
            TerminalChatTextFormatting.systemMessageColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
    }

    func writeChat(
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
    func writeChatMeasured(
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

    func writeStreamingChat(
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

    func flushChatOutput() {
        flushPendingStreamingWrites()
        synchronizeStandardOutput()
    }

    func synchronizeStandardOutput() {
        guard standardOutputIsTerminal else {
            return
        }
        standardOutput?.synchronizeFile()
    }

    func writeRawChatError(_ text: String) {
        let normalizedText = chatSpacingNormalized(text, for: .standardError)
        recordChannelContent(after: normalizedText, for: .standardError)
        updateChatLineInsetState(after: normalizedText, for: .standardError)
        writeDirect(normalizedText, to: .standardError)
    }

    var standardOutputIsTerminal: Bool {
        channelIsTerminal(.standardOutput)
    }

    var standardErrorIsTerminal: Bool {
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
    var currentOutputTrailingNewlineCount: Int {
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
    func isAtLineStart(for channel: OutputChannel) -> Bool {
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

    func currentCursorState(for channel: OutputChannel) -> CursorState {
        withCursorState(for: channel) { $0 }
    }

    func restoreCursorState(
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

    // MARK: - Direct terminal writes

    func writeDirect(_ text: String, to channel: OutputChannel) {
        flushPendingStreamingWrites()
        emitDirect(text, to: channel)
    }

    func emitDirect(_ text: String, to channel: OutputChannel) {
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
