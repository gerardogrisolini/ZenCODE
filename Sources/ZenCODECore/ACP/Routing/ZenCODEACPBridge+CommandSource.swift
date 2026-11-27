//
//  ZenCODEACPBridge+CommandSource.swift
//  ZenCODE
//
//  The operator's own text block of an ACP prompt, and the context the client
//  sent around it, so a command or an agent mention typed after Xcode's
//  context is still routed, and the operator's text alone is what a saved
//  session presents.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// The operator's text block of a prompt: the last non-blank text block
/// addressed to the user, when it is not Xcode context and every eligible
/// text block before it is. Rendered resources, media, and text not addressed
/// to the user are never operator input.
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
        let texts = userTextBlocks(in: blocks)
        guard let last = texts.last,
              !isXcodeContextBlock(last.text),
              texts.dropLast().allSatisfy({ isXcodeContextBlock($0.text) }) else { return nil }
        return ACPPromptCommandSource(text: last.text, blockIndex: last.index, followsXcodeContext: texts.count > 1)
    }

    /// The non-blank text blocks of `blocks` addressed to the user, in order:
    /// the text as the block carries it (`rawText`, which the rendered prompt
    /// holds) and trimmed (`text`), with the block's position.
    private static func userTextBlocks(in blocks: [Any]) -> [(index: Int, text: String, rawText: String)] {
        var texts: [(index: Int, text: String, rawText: String)] = []
        for (index, block) in blocks.enumerated() {
            let rawText: String
            if let text = block as? String {
                rawText = text
            } else {
                guard let object = block as? [String: Any],
                      object["type"] == nil || (object["type"] as? String)?.lowercased() == "text",
                      let text = object["text"] as? String else {
                    continue
                }
                if let rawAnnotations = object["annotations"] {
                    guard let annotations = rawAnnotations as? [String: Any] else { continue }
                    if let rawAudience = annotations["audience"] {
                        guard let audience = rawAudience as? [String], audience.contains("user") else { continue }
                    }
                }
                rawText = text
            }
            if let text = rawText.nilIfBlank {
                texts.append((index, text, rawText))
            }
        }
        return texts
    }

    /// The context blocks Xcode sent in `blocks`, each as the rendered prompt
    /// holds it (``PromptContentFormatter/renderPromptText(from:)`` joins the
    /// blocks as they are): every text block addressed to the user for which
    /// ``isXcodeContextBlock(_:)`` holds. A prompt whose text blocks are all
    /// context has no text of the operator, only an attachment, say.
    static func xcodeContextBlocks(in blocks: [Any]) -> [String] {
        userTextBlocks(in: blocks).filter { isXcodeContextBlock($0.text) }.map(\.rawText)
    }

    /// What the operator typed in the prompt a turn sends the model,
    /// `modelPrompt`: the prompt without the Xcode context `contextBlocks`
    /// (see ``xcodeContextBlocks(in:)``), each removed once with the blank
    /// line that follows it, or alone at the end, and trimmed. `nil` when
    /// nothing was removed or nothing is left, so the prompt is presented as
    /// it is. Only for presentation: the model gets `modelPrompt`.
    ///
    /// A block is matched as the rendered prompt holds it, else trimmed: the
    /// whole prompt and the context a command turn passes before its prompt
    /// are both trimmed, which cuts the whitespace a block starts or ends with.
    static func promptDisplayText(of modelPrompt: String, removingXcodeContext contextBlocks: [String]) -> String? {
        var text = modelPrompt
        var didRemove = false
        for block in contextBlocks {
            let candidates = [block, block.trimmingCharacters(in: .whitespacesAndNewlines)]
            for candidate in candidates where !candidate.isEmpty {
                if let range = text.range(of: candidate + "\n\n") {
                    text.removeSubrange(range)
                } else if text.hasSuffix(candidate) {
                    text.removeLast(candidate.count)
                } else {
                    continue
                }
                didRemove = true
                break
            }
        }
        guard didRemove, let displayText = text.nilIfBlank else { return nil }
        return displayText
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
