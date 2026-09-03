//
//  TerminalChatRenderCoordinator+Messages.swift
//  ZenCODE
//

import Foundation

/// Transcript message writers (prompts, failures, summaries, operational and interleaved output) plus the external terminal-prompt suspension guard.
extension TerminalChatRenderCoordinator {
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

    /// Writes the end-of-turn file-change section after every currently
    /// renderable overview. Unlike the interleaved variant, this deliberately
    /// does not render deferred overviews after the summary: the summary is the
    /// terminal section which closes a completed prompt.
    func writeFinalFileChangeSummaryMessage(_ text: String) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        renderPendingOverviewsIfIdle()
        writeChat(
            TerminalChatTextFormatting.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: standardErrorIsTerminal
            ),
            to: .standardError
        )
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

    /// Establishes an exclusive external-writer phase for an interactive prompt.
    /// Existing transient rows are retired before the card is drawn; subsequent
    /// coordinator output is accumulated rather than emitted into the card.
    func beginExternalTerminalPrompt(maximumInPlaceRows: Int? = nil) {
        guard externalTerminalPromptDepth == 0 else {
            externalTerminalPromptDepth += 1
            return
        }

        overviewState.isSuspended = true
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        clearActiveToolBeforeExternalTerminalPrompt(
            maximumInPlaceRows: maximumInPlaceRows
        )
        parkSubAgentOverviewForReplay(
            maximumInPlaceRows: maximumInPlaceRows
        )

        // The consent reader's card and echoed answer both terminate with a
        // newline, and the caller adds a second boundary newline before ending
        // this phase. Format deferred output against that future cursor state,
        // not against the rows just removed above.
        var postPromptCursorState = CursorState()
        postPromptCursorState.spacing.trailingNewlineCount = 2
        restoreCursorState(postPromptCursorState, for: .standardError)
        externalTerminalPromptDepth = 1
    }

    /// Releases the external writer, resolves deferred overview arbitration into
    /// the same ordered batch as any tool/stream progress, then emits that batch
    /// below the completed card.
    func endExternalTerminalPrompt() {
        guard externalTerminalPromptDepth > 0 else { return }
        guard externalTerminalPromptDepth == 1 else {
            externalTerminalPromptDepth -= 1
            return
        }

        // Keep the external phase active while pending streams and overviews are
        // resolved, so they join the tail of the same FIFO rather than overtaking
        // tool bytes that were accumulated earlier in the authorization wait.
        flushPendingStreamingWrites()
        overviewState.isSuspended = false
        renderPendingOverviewsIfIdle()
        flushPendingStreamingWrites()
        externalTerminalPromptDepth = 0
        flushExternalTerminalPromptWrites()
    }
}
