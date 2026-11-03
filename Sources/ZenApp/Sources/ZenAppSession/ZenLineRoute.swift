//
//  ZenLineRoute.swift
//  ZenApp
//
//  Where a submitted line goes, decided as the terminal decides it.
//

import Foundation
import ZenCODECore

/// What a window does with a line the operator submits.
public enum ZenLineRoute: Equatable, Sendable {
    /// Nothing runs: the line runs now.
    case run
    /// A line runs, and this command runs while a prompt is generating: it
    /// runs at once, beside the running line.
    case runBeside
    /// The line waits in the window's queue until the lines before it end.
    case queue
    /// The line is refused with this message; the draft is kept.
    case refuse(String)

    /// The route of `line` (already trimmed by the caller or not), as the
    /// terminal routes a submitted line:
    /// - nothing runs and nothing waits: `.run`;
    /// - nothing runs but lines wait: `.queue`, so the queue keeps its order;
    /// - a line runs and the line is a command that runs while a prompt is
    ///   generating (`registry.isAvailableDuringGeneration(_:)`): `.runBeside`;
    /// - a line runs and the line is any other command: `.refuse`, with the
    ///   terminal's message (a hidden command answers as it does when hidden);
    /// - a line runs and the line is a prompt: `.queue`.
    public static func route(
        for line: String,
        isLineRunning: Bool,
        hasQueuedLines: Bool,
        registry: ChatCommandRegistry,
        context: ChatCommandContext
    ) -> ZenLineRoute {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLineRunning else {
            return hasQueuedLines ? .queue : .run
        }
        guard trimmed.hasPrefix("/") else {
            return .queue
        }
        if registry.isAvailableDuringGeneration(trimmed) {
            return .runBeside
        }
        return .refuse(generatingCommandMessage(for: trimmed, registry: registry, context: context))
    }

    /// The answer to a command that cannot run while a prompt is running, as
    /// the terminal gives it.
    static func generatingCommandMessage(
        for line: String,
        registry: ChatCommandRegistry,
        context: ChatCommandContext
    ) -> String {
        let message: String
        if let hidden = registry.message(forHiddenLine: line, context: context, isGenerating: true) {
            message = hidden
        } else if registry.descriptor(forLine: line) == nil {
            message = ChatCommandRegistry.unknownCommandMessage(for: line)
        } else {
            message = "ZenCODE: command '\(commandToken(of: line))' is unavailable while a prompt is running."
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first word of a command line.
    static func commandToken(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? trimmed
    }
}
