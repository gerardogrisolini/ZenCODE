//
//  ChatTurnBlockRules.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import ToolCore

/// The rules that close the assistant blocks of a chat turn, shared by the
/// transcript (``ChatTranscriptTurn``) and the session log
/// (``ChatSessionStateReducer``), so the two can never disagree on what a
/// block holds.
///
/// A block is the assistant content and the reasoning streamed between two
/// boundaries: the first start of a tool call, an automatic `/goal`
/// continuation, and the end of the turn.
enum ChatTurnBlockRules {
    /// `true` when the block has something to record: non-blank content or
    /// non-blank reasoning.
    static func hasBlock(assistantContent: String, reasoningContent: String) -> Bool {
        assistantContent.nilIfBlank != nil || reasoningContent.nilIfBlank != nil
    }

    /// `true` when the turn's last block holds only reasoning while the
    /// runtime returned a non-blank final response text: the final text is
    /// then the block's content, and the reasoning is dropped.
    static func shouldPromoteReasoningToContent(
        finalResponseText: String,
        assistantContent: String,
        reasoningContent: String
    ) -> Bool {
        let finalText = finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty,
              assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// The last block of a turn, before it is closed: the block as streamed,
    /// or the final response text as its content when
    /// ``shouldPromoteReasoningToContent(finalResponseText:assistantContent:reasoningContent:)``
    /// applies. `finalResponseText` is `nil` for a turn that failed or was
    /// cancelled, whose block is closed as streamed.
    static func finalBlock(
        assistantContent: String,
        reasoningContent: String,
        finalResponseText: String?
    ) -> (assistantContent: String, reasoningContent: String) {
        guard let finalResponseText,
              shouldPromoteReasoningToContent(
                  finalResponseText: finalResponseText,
                  assistantContent: assistantContent,
                  reasoningContent: reasoningContent
              ) else {
            return (assistantContent, reasoningContent)
        }
        return (finalResponseText, "")
    }
}
