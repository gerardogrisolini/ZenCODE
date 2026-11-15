//
//  TerminalChatRenderCoordinator+ToolCallPreview.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/11/26.
//

import Foundation

/// Live drawing of a file write or edit while the model is still writing its
/// tool call. The rows are append-only transcript on the tool-block channel.
/// When the compact block follows the preview of the same call right away, it
/// omits the header and target the preview already showed; otherwise it is
/// drawn exactly as without a preview.
extension TerminalChatRenderCoordinator {
    // MARK: - Tool-call preview

    func writeToolCallPreview(
        _ preview: DirectAgentToolCallPreview,
        maximumInPlaceRows: Int? = nil
    ) {
        switch preview {
        case let .toolStarted(name):
            // A new call ends the previous one even when it is not drawn.
            endToolCallPreview()
            guard TerminalToolCallPreviewFormatter.drawsTool(named: name) else {
                return
            }
            prepareForToolCallPreview(maximumInPlaceRows: maximumInPlaceRows)
            if let header = toolCallPreviewFormatter.begin(toolNamed: name) {
                writeToolCallPreviewText(header)
            }
        case .ended:
            endToolCallPreview()
        case .parameterStarted, .parameterText, .parameterEnded:
            guard toolCallPreviewFormatter.isOpen || toolCallPreviewFormatter.isSuspended else {
                return
            }
            if toolCallPreviewFormatter.resumes(with: preview) {
                // The call was interrupted: its header is reopened after the
                // same preparation as its start. The status bar's capacity is
                // read only at the start of a drawn call, so an owned overview
                // is released within the rows it recorded itself.
                prepareForToolCallPreview(maximumInPlaceRows: nil)
            }
            writeToolCallPreviewText(
                toolCallPreviewFormatter.consume(
                    preview,
                    columns: freshColumnWidthProvider
                )
            )
        }
    }

    /// Closes the rows of an open preview before other output, leaving the
    /// cursor at the start of a row. Every other transcript write, tool block,
    /// and end of turn calls it first, so no output can land inside a preview
    /// row. The call is only suspended: its next drawn text reopens it.
    func interruptToolCallPreviewIfNeeded() {
        guard toolCallPreviewFormatter.isOpen else {
            return
        }
        writeToolCallPreviewText(
            toolCallPreviewFormatter.interrupt(columns: freshColumnWidthProvider)
        )
        flushPendingStreamingWrites()
    }

    /// Ends the call: an open preview is closed with the same text as an
    /// interruption, and a suspended one is forgotten without output. Its end,
    /// a new call, the end of the turn's streaming, and a new transcript turn
    /// call it, so a call never reopens past them. The call it drew is kept for
    /// the tool block that follows it.
    func endToolCallPreview() {
        let wasOpen = toolCallPreviewFormatter.isOpen
        let ended = toolCallPreviewFormatter.finish(columns: freshColumnWidthProvider)
        writeToolCallPreviewText(ended.text)
        if wasOpen {
            flushPendingStreamingWrites()
        }
        if let drawn = ended.drawn {
            pendingToolCallPreviewDrawing = drawn
            pendingToolCallPreviewDrawingSequence = emittedWriteCount
        }
    }

    /// Forgets the drawings of a turn that ended, so a block of a later turn
    /// never omits a header it did not see.
    func clearToolCallPreviewDrawings() {
        pendingToolCallPreviewDrawing = nil
        pendingToolCallPreviewDrawingSequence = nil
        previewMergedToolCallID = nil
    }

    /// Whether the preview header already showed this call's canonical tool
    /// name and its path, no output was emitted since, and the terminal can
    /// rewrite the block in place, so the block draws only its status row. The
    /// drawing is consumed once, and its call keeps the decision for its
    /// completion and for a start republished after a bottom-overlay
    /// transition. A channel that cannot rewrite keeps the full block: its
    /// completion is append-only.
    func previewAlreadyShowedHeader(for toolCall: DirectAgentToolCall) -> Bool {
        if previewMergedToolCallID == toolCall.id {
            return true
        }
        let drawing = pendingToolCallPreviewDrawing
        let sequence = pendingToolCallPreviewDrawingSequence
        pendingToolCallPreviewDrawing = nil
        pendingToolCallPreviewDrawingSequence = nil
        guard let drawing,
              drawing.pathWasShown,
              standardErrorIsTerminal,
              sequence == emittedWriteCount,
              let target = ToolCallPresentation.displayToolTarget(for: toolCall),
              drawing.path == target,
              TerminalToolCallPreviewFormatter.drawnTool(named: toolCall.name)?.name
                  == drawing.toolName
        else {
            return false
        }
        previewMergedToolCallID = toolCall.id
        return true
    }

    /// Rows of a preview are open on screen. A suspended call has none, so it
    /// defers nothing.
    var isStreamingToolCallPreview: Bool {
        toolCallPreviewFormatter.isOpen
    }

    /// The same transcript preparation as a tool block: the thought and the
    /// assistant stream are closed, an owned tool block and sub-agent overview
    /// are released as for other interleaved output, and the header starts on
    /// a fresh row after the tool separator.
    private func prepareForToolCallPreview(maximumInPlaceRows: Int?) {
        interruptActiveToolForInterleavedOutputIfNeeded()
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        clearOwnedSubAgentOverviewBeforeInterleavedOutput(
            maximumInPlaceRows: maximumInPlaceRows
        )
        prepareForToolOutput()
        if !isAtLineStart(for: .standardError) {
            writeStreamingChat("\n", to: .standardError)
        }
    }

    /// Preview rows pass through the streaming writer, so they are coalesced
    /// like the other streams and keep the margin and spacing state. Spacing
    /// is preserved: blank source rows are content, not separators.
    private func writeToolCallPreviewText(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        writeStreamingChat(text, to: .standardError, preservesSpacing: true)
    }
}
