//
//  ZenCODEACPBridge+CommandSource.swift
//  ZenCODE
//
//  The operator's own text block of an ACP prompt, and the context the client
//  sent around it, so a command or an agent mention typed after Xcode's
//  context is still routed.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// The operator's text block of a prompt: the last non-blank text block
/// addressed to the user, when every text block before it is context Xcode
/// sends. Rendered resources, media, and assistant-only text are not input
/// typed by the operator and never name a command.
struct ACPPromptCommandSource {
    /// The operator's text, trimmed.
    let text: String
    /// The position of its block in the prompt.
    let blockIndex: Int
    /// Whether Xcode context blocks precede it.
    let followsXcodeContext: Bool
}

extension ZenCODEACPBridge {
    /// The operator's text block of `blocks`, or `nil` when the prompt's text
    /// is ambiguous: two text blocks of the operator, or text before it that
    /// is not Xcode context.
    static func commandSource(from blocks: [Any]) -> ACPPromptCommandSource? {
        var texts: [(index: Int, text: String)] = []
        for (index, block) in blocks.enumerated() {
            let rawText: String
            if let text = block as? String {
                rawText = text
            } else {
                guard let object = block as? [String: Any],
                      (object["type"] as? String ?? "text").lowercased() == "text",
                      let text = object["text"] as? String else {
                    continue
                }
                if let annotations = object["annotations"] as? [String: Any],
                   let audience = annotations["audience"] as? [String],
                   !audience.contains("user") {
                    continue
                }
                rawText = text
            }
            if let text = rawText.nilIfBlank {
                texts.append((index, text))
            }
        }
        guard let last = texts.last,
              texts.dropLast().allSatisfy({ isXcodeContextBlock($0.text) }) else { return nil }
        return ACPPromptCommandSource(text: last.text, blockIndex: last.index, followsXcodeContext: texts.count > 1)
    }

    /// Whether `text`, already trimmed, is a context block Xcode sends before
    /// the operator's text: a `<system-reminder>`, or the project structure,
    /// whose heading is `Project structure:` or, in current Xcode releases,
    /// `Project structure (these are Xcode workspace-relative paths …):`.
    static func isXcodeContextBlock(_ text: String) -> Bool {
        (text.hasPrefix("<system-reminder>") && text.hasSuffix("</system-reminder>"))
            || text.hasPrefix("Project structure:")
            || text.hasPrefix("Project structure (")
    }

    /// Whether `text` names a command the bridge routes itself, after the
    /// agent mention it may start with: `/goal`, `/plan`, `/review`, `/tasks`,
    /// `/telegram`, `/changes`, or `/undo`.
    static func namesACPRoutedCommand(_ text: String) -> Bool {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("@") {
            line = String(line.drop { !$0.isWhitespace })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch ChatCommandRegistry.commandToken(from: line) {
        case changesCommandToken, undoCommandToken, tasksCommandToken, telegramCommandToken:
            return true
        default:
            return CoordinatorCommandParser.parse(line) != nil
        }
    }

    /// The source a prompt routes its command from, when it is not the whole
    /// rendered prompt: a workspace command in its own block, as before, and
    /// any routed command typed after Xcode's context. Without that context a
    /// coordinator command keeps the whole prompt, so a client that sends a
    /// resource with `/goal` still gives the goal its content.
    static func routedCommandSource(from blocks: [Any]) -> ACPPromptCommandSource? {
        guard let source = commandSource(from: blocks),
              isWorkspaceCommand(source.text)
                || (source.followsXcodeContext && namesACPRoutedCommand(source.text)) else {
            return nil
        }
        return source
    }

    /// The source a prompt routes from: the commands of
    /// ``routedCommandSource(from:)`` and, after Xcode's context, a leading
    /// mention of a known agent, which a prompt that starts with the context
    /// would never reach. A mention of no known agent keeps the whole prompt.
    func routedPromptSource(from blocks: [Any]) throws -> ACPPromptCommandSource? {
        if let source = Self.routedCommandSource(from: blocks) {
            return source
        }
        guard let source = Self.commandSource(from: blocks), source.followsXcodeContext,
              try resolveLeadingACPAgentMention(in: source.text) != nil else {
            return nil
        }
        return source
    }

    /// The rest of the prompt around `source`, rendered as the turn renders
    /// it: the context a turn routed from `source` passes to the model.
    static func editorContext(around source: ACPPromptCommandSource, in blocks: [Any]) -> String? {
        var context = blocks
        context.remove(at: source.blockIndex)
        return PromptContentFormatter.renderPromptText(from: context).nilIfBlank
    }

    /// The prompt a turn routed from the operator's block generates, after
    /// the client's context.
    static func modelPrompt(_ prompt: String, editorContext: String?) -> String {
        guard let editorContext else { return prompt }
        return editorContext + "\n\n" + prompt
    }
}
