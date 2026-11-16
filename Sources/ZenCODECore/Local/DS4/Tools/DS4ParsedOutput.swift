//
//  DS4ParsedOutput.swift
//  ZenCODE
//
//  The output of DS4GeneratedOutputParser: the streamed visible and reasoning
//  deltas and the parsed result of one generated assistant turn.
//

import Foundation
import ToolCore

/// A streamed piece of generated output.
enum DS4ParsedOutputDelta: Sendable, Equatable {
    case visible(String)
    case thought(String)
}

/// The result of one generated assistant turn.
struct DS4ParsedOutput: Sendable {
    /// Visible answer text, without reasoning and without any tool markup.
    let visibleText: String
    /// Reasoning text from `<think>…</think>` spans.
    let reasoningText: String
    /// Executable tool calls. Empty whenever `parseError` is set: like
    /// ds4-agent, a malformed block executes nothing.
    let toolCalls: [DirectAgentToolCall]
    /// `toolCalls` with arguments in the order the model emitted them, for an
    /// exact replay through `DS4ToolCallRenderer` (DirectAgentToolCall keeps a
    /// key-sorted canonical JSON).
    let toolCallReplays: [DS4ToolCallReplay]
    /// Malformed or incomplete tool-call output, to be returned to the model.
    let parseError: DS4ToolParseError?
    /// Every chunk passed to `consume(_:)`, concatenated.
    let rawText: String
    /// Deltas released by `finish()` (text held back while it could still
    /// have started a marker). Already included in `visibleText`/`reasoningText`.
    let finalDeltas: [DS4ParsedOutputDelta]
}
