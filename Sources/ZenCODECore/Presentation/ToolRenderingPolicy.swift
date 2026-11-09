//
//  ToolRenderingPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Decisions about how a tool call is presented that every surface shares: the
/// terminal, the sub-agent views, and the activity rows of the Telegram
/// channel. They produce no styling and depend on no terminal type, so a
/// channel can apply them without importing terminal presentation.
enum ToolRenderingPolicy {
    /// Tool executions that remain observable to the runtime but have no terminal
    /// representation (nor one in the activity rows Telegram mirrors from it).
    /// Keep this presentation-only: authorization, dispatch, transcript
    /// persistence and shared-chat delivery must still see the call.
    static func shouldSuppressToolRendering(for toolName: String) -> Bool {
        toolName == "agent.message"
    }

    /// Whether a completed call failed, as its status marker shows it: the
    /// result failed, or `local.exec` ended with a non-zero exit code. The
    /// terminal marks it ⚠️, Telegram's activity rows ❌.
    static func toolResultIsFailure(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Bool {
        let hasFailedProcessExit = compactLocalExecExitCode(for: toolCall, result: result)
            .map { $0 != 0 } ?? false
        return result.isFailure || hasFailedProcessExit
    }

    /// Reads only the leading, complete canonical process-result line. In
    /// particular, an arbitrary phrase or a later stdout line containing
    /// `exit_code:` is not treated as structured process metadata, avoiding
    /// false failures from tool output text.
    static func compactLocalExecExitCode(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Int? {
        guard toolCall.name == "local.exec" else {
            return nil
        }
        for payload in [result.summary, result.output] {
            guard let line = payload.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            ).first else {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("exit_code: "),
               case let value = trimmed.dropFirst("exit_code: ".count),
               isCanonicalExitCode(value),
               let exitCode = Int(value) {
                return exitCode
            }
        }
        return nil
    }

    /// Whether `value` is an optionally negative run of digits, the shape of
    /// the exit code of a process result.
    static func isCanonicalExitCode(_ value: Substring) -> Bool {
        let digits = value.first == "-" ? value.dropFirst() : value
        return !digits.isEmpty && digits.allSatisfy(\.isWholeNumber)
    }
}
