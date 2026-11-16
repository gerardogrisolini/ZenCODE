//
//  TerminalMarkdownStreamFormatter+InlineStreaming.swift
//  ZenCODE
//
//  Inline rendering of partially streamed lines: the safe emit boundary, the
//  incremental line-start state and the Markdown renderer configuration.
//

import Foundation
import Markdown

extension TerminalMarkdownStreamFormatter {
    /// Renders the tail of a partially-streamed line as inline markdown.
    ///
    /// - Note: Once a line has started streaming it can no longer become a block
    ///   construct (e.g. a table header): its already-written prefix cannot be
    ///   retracted, so a later `|` renders as literal inline text.
    func renderInlineFragment(_ fragment: String) -> String {
        // `fragment` follows text already written directly to the terminal. A
        // leading mark, joiner, regional indicator, or emoji modifier can
        // therefore complete the final grapheme in that emitted text. Do not
        // put that cluster after `inlineParsingSentinel`: the Markdown parser
        // is allowed to coalesce or discard otherwise-invisible Unicode at a
        // synthetic boundary (and its behaviour has differed between the
        // Darwin and Linux implementations). Emit the continuation unchanged,
        // then parse only the markdown-capable remainder.
        let continuation = leadingGraphemeContinuation(in: fragment)
        if !continuation.prefix.isEmpty {
            return continuation.prefix + renderInlineFragment(continuation.remainder)
        }
        guard mayContainMarkdown(in: fragment) else {
            return fragment
        }
        // A partial tail starts in the middle of an already-emitted logical
        // line. Prefixing a zero-width, non-whitespace sentinel keeps leading
        // `-`, `#`, `>` and similar characters as inline prose rather than
        // allowing the document parser to create a fresh block. Remove only the
        // synthetic first occurrence after rendering; user content remains
        // untouched.
        let source = Self.inlineParsingSentinel + sanitizedMarkdownSource(fragment)
        var renderer = makeRenderer()
        let rendered = renderer.visit(Document(parsing: source))
        guard let sentinelRange = rendered.range(of: Self.inlineParsingSentinel) else {
            return rendered
        }
        return rendered.replacingCharacters(in: sentinelRange, with: "")
    }

    /// Separates the first independently-segmented `Character` when its first
    /// scalar can continue the grapheme cluster emitted in the preceding
    /// stream delta. `String` cannot expose a grapheme that spans two distinct
    /// values, so preserve this small raw prefix before Markdown sees it.
    private func leadingGraphemeContinuation(
        in fragment: String
    ) -> (prefix: String, remainder: String) {
        guard let firstScalar = fragment.unicodeScalars.first,
              Self.isGraphemeContinuationStarter(firstScalar) else {
            return ("", fragment)
        }
        let end = fragment.index(after: fragment.startIndex)
        return (
            String(fragment[..<end]),
            String(fragment[end...])
        )
    }

    /// Unicode scalars which may extend a grapheme begun in a previous delta.
    /// General-category marks cover combining accents and script-specific
    /// marks; the explicit ranges cover joiner-based emoji, flags, modifiers,
    /// variation selectors, tag sequences, and Hangul medial/final jamo.
    private static func isGraphemeContinuationStarter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            break
        }

        let value = scalar.value
        return value == 0x200C // ZERO WIDTH NON-JOINER
            || value == 0x200D // ZERO WIDTH JOINER
            || (0x1100...0x11FF).contains(value) // Hangul jamo
            || (0x1F1E6...0x1F1FF).contains(value) // Regional indicators
            || (0x1F3FB...0x1F3FF).contains(value) // Emoji modifiers
            || (0xFE00...0xFE0F).contains(value) // Variation selectors
            || (0xE0020...0xE007F).contains(value) // Emoji tag sequence
            || (0xE0100...0xE01EF).contains(value) // Variation Selectors Supplement
    }

    /// End of the newly safe pending-line prefix: nothing while a line-start block
    /// marker is unresolved (cached in `pendingLineStartState`), otherwise up to
    /// the first `streamingStopChars` character.
    func safeStreamingEmitEnd(in line: String) -> String.Index {
        guard case .resolved = pendingLineStartState else {
            return line.startIndex
        }
        return line.firstIndex { Self.streamingStopChars.contains($0) } ?? line.endIndex
    }

    /// Feeds only newly appended characters into the block-marker classifier.
    /// It mirrors the prior full-line block-marker decisions without repeatedly
    /// trimming/scanning the complete pending line while a marker candidate is
    /// split across many small deltas.
    mutating func updatePendingLineStartState(with segment: Substring) {
        for character in segment {
            switch pendingLineStartState {
            case .ambiguousBlockMarker, .resolved:
                return
            default:
                advancePendingLineStartState(with: character)
            }
        }
    }

    private mutating func advancePendingLineStartState(with character: Character) {
        switch pendingLineStartState {
        case .leadingWhitespace:
            guard !isBlockMarkerWhitespace(character) else {
                return
            }
            switch character {
            case ">":
                pendingLineStartState = .ambiguousBlockMarker
            case "#":
                pendingLineStartState = .hashRun(1)
            case "-":
                pendingLineStartState = .dashRun(1)
            case "+":
                pendingLineStartState = .plus
            default:
                pendingLineStartState = character.isNumber ? .digitRun(1) : .resolved
            }
        case .hashRun(let count):
            pendingLineStartState = character == "#"
                ? (count >= 6 ? .resolved : .hashRun(count + 1))
                : stateAfterMarker(character)
        case .dashRun(let count):
            if character == "-" {
                pendingLineStartState = .dashRun(min(3, count + 1))
            } else if count >= 3 {
                pendingLineStartState = character.isWhitespace ? .ambiguousBlockMarker : .resolved
            } else {
                pendingLineStartState = stateAfterMarker(character)
            }
        case .plus, .orderedListDot:
            pendingLineStartState = stateAfterMarker(character)
        case .digitRun(let count):
            if character.isNumber {
                pendingLineStartState = count >= 9 ? .resolved : .digitRun(count + 1)
            } else if character == "." {
                pendingLineStartState = .orderedListDot
            } else {
                // Trimming removes a trailing whitespace run, so wait until a
                // later non-whitespace character proves this is not all digits.
                pendingLineStartState = isBlockMarkerWhitespace(character) ? .deferredWhitespace : .resolved
            }
        case .deferredWhitespace:
            if !isBlockMarkerWhitespace(character) {
                pendingLineStartState = .resolved
            }
        case .ambiguousBlockMarker, .resolved:
            return
        }
    }

    private func stateAfterMarker(_ character: Character) -> PendingLineStartState {
        if character == " " || character == "\t" {
            return .ambiguousBlockMarker
        }
        return isBlockMarkerWhitespace(character) ? .deferredWhitespace : .resolved
    }

    private func isBlockMarkerWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            Self.blockMarkerWhitespace.contains($0)
        }
    }

    func makeRenderer() -> TerminalSwiftMarkdownRenderer {
        // Structured surfaces (tables, thematic rules, code blocks) still need a
        // terminal width to preserve borders and padding; free conversational
        // prose is never reflowed here and relies on the terminal's own wrap.
        // Leave one column for the chat inset plus any presentation-only prefix
        // applied by the caller after Markdown has been laid out.
        TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: supportsHyperlinks,
            renderWidth: codeBlockWidth,
            palette: palette,
            codeBlocksUseEraseToEndOfLine: codeBlocksUseEraseToEndOfLine
        )
    }

    /// Code is emitted directly by the stream (rather than via `makeRenderer`)
    /// and therefore reserves the same chat inset and presentation prefix as a
    /// complete Markdown renderer created above.
    var codeBlockWidth: Int {
        renderWidth > 0 ? max(1, renderWidth - 1 - presentationPrefixWidth) : 0
    }

    func shouldFlushPendingLineForStreaming(_ line: String) -> Bool {
        activeCodeFence == nil && blockKind == nil && !mayContainMarkdown(in: line)
    }
}
