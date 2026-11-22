//
//  TerminalMarkdownStreamFormatter+InlineSpanStreaming.swift
//  ZenCODE
//
//  Early emission of closed inline constructs on a pending prose line, and
//  the validated word-level continuation of a line committed that way.
//

import Foundation
import Markdown

extension TerminalMarkdownStreamFormatter {
    /// Delimiters that must not survive as literal text in an early-emitted
    /// prefix: a leftover could still pair with a delimiter that arrives later.
    static let closedPrefixDelimiterScalars: Set<Unicode.Scalar> = [
        "`", "*", "_", "~", "[", "]"
    ]
    /// Characters that always keep the conservative fallback (no early
    /// emission): autolinks/HTML, table cells, backslash escapes and CR.
    static let closedPrefixFallbackScalars: Set<Unicode.Scalar> = [
        "<", "|", "\\", "\r"
    ]
    /// Line openings that may still be parsed as a block construct once the
    /// complete line is known, so the line must not be committed as prose.
    private static let blockLikeLinePrefixes = [
        "```", "~~~", "***", "___", "---",
        "* ", "*\t", "- ", "-\t", "+ ", "+\t"
    ]

    /// Whether a line that has not produced output yet may be committed as a
    /// paragraph. The early emission is irrevocable, so any opening that could
    /// still turn the complete line into a fence, list item, thematic break,
    /// heading, quote, table or HTML block keeps the whole-line rendering.
    func lineStartAllowsInlineCommit(_ line: String) -> Bool {
        guard let first = line.first,
              !first.isWhitespace,
              !first.isNumber,
              !["|", "<", "#", ">"].contains(first) else {
            return false
        }
        return !Self.blockLikeLinePrefixes.contains(where: line.hasPrefix)
    }

    /// Renders `prefix` when it is a self-contained inline sequence whose
    /// output cannot change once more text of the same line arrives.
    ///
    /// The prefix always ends right before a space or tab, where a final
    /// delimiter run is already flanked exactly as at the end of the text, and
    /// the inline scanner only proposes it when every construct is closed.
    /// The parse validates that proposal on the raw source: a `Text` node that
    /// still contains a delimiter means an opener remained literal and could
    /// pair later. Sanitisation is deliberately not applied to the check (it
    /// would hide an open `**`); instead it must be the identity, so pairing in
    /// the rest of the line is not shifted by this split.
    ///
    /// - Parameters:
    ///   - atLineStart: the prefix begins the logical line; the whole-line
    ///     renderer parses it without `inlineParsingSentinel`, so both
    ///     renderings must agree, and artifact metadata headers stay whole.
    ///   - isCommittedContinuation: the line already emitted a validated prefix,
    ///     so it was markdown before this split and must still be parsed even
    ///     when this piece alone looks like plain prose.
    func validatedClosedInlinePrefix(
        _ prefix: String,
        atLineStart: Bool,
        isCommittedContinuation: Bool
    ) -> String? {
        guard !prefix.isEmpty,
              !prefix.unicodeScalars.contains(where: Self.closedPrefixFallbackScalars.contains),
              isCommittedContinuation || mayContainMarkdown(in: prefix),
              !removesUnbalancedStrongMarkers || hasBalancedStrongMarkers(in: prefix) else {
            return nil
        }
        let document = Document(parsing: Self.inlineParsingSentinel + prefix)
        guard Self.isSelfContainedInlineParagraph(document) else {
            return nil
        }
        let rendered = renderParsedInlineFragment(document)
        guard atLineStart else {
            return rendered
        }
        let lineDocument = Document(parsing: prefix)
        guard !Self.startsWithArtifactMetadataLabel(lineDocument) else {
            return nil
        }
        var renderer = makeRenderer()
        return renderer.visit(lineDocument) == rendered ? rendered : nil
    }

    /// One paragraph whose inline tree has no literal delimiter, raw HTML or
    /// line break: nothing can remain on the parser's delimiter stack.
    static func isSelfContainedInlineParagraph(_ document: Document) -> Bool {
        guard document.childCount == 1,
              let paragraph = document.child(at: 0) as? Paragraph else {
            return false
        }
        return inlineChildrenAreClosed(paragraph)
    }

    private static func inlineChildrenAreClosed(_ markup: Markup) -> Bool {
        for child in markup.children {
            switch child {
            case let text as Text:
                if text.string.unicodeScalars.contains(where: closedPrefixDelimiterScalars.contains) {
                    return false
                }
            case is InlineHTML, is SoftBreak, is LineBreak:
                return false
            default:
                if !inlineChildrenAreClosed(child) {
                    return false
                }
            }
        }
        return true
    }

    /// The canonical artifact metadata header is recolored only when the
    /// renderer sees its label together with the following counts, so a
    /// prefix ending after the label must not be emitted on its own.
    private static func startsWithArtifactMetadataLabel(_ document: Document) -> Bool {
        guard let paragraph = document.child(at: 0) as? Paragraph,
              let label = paragraph.child(at: 0) as? Strong else {
            return false
        }
        return TerminalSwiftMarkdownRenderer.isArtifactMetadataLabel(label)
    }

    /// Linear, incremental pre-scan of the pending tail. It approximates the
    /// CommonMark/GFM inline rules (code spans, emphasis and strikethrough
    /// delimiter runs, links, smart quotes) only to propose the latest space or
    /// tab boundary at which every construct looks closed. The Markdown parse
    /// validates each proposal, except smart quotes, which the parsed tree
    /// cannot expose: an unmatched opening quote renders differently once its
    /// closer arrives, so quotes are tracked here conservatively.
    ///
    /// Offsets are UTF-8 counts into the pending line; no `String.Index` is
    /// retained across a mutation of that string.
    struct InlineSpanBoundaryScanner {
        enum ScalarClass {
            case whitespace
            case punctuation
            case other
        }

        private struct PendingRun {
            let marker: Unicode.Scalar
            var length: Int
            let before: ScalarClass
            let beforeScalar: Unicode.Scalar?
        }

        private struct DelimiterOpener {
            let marker: Unicode.Scalar
            var length: Int
        }

        private struct BracketScope {
            let emphasisDepth: Int
            let singleQuoteOpeners: Int
            let doubleQuoteOpeners: Int
        }

        /// UTF-8 bytes of the pending line already classified.
        private(set) var scannedUTF8Count = 0
        /// UTF-8 offset of the space or tab that ends the latest closed prefix.
        private(set) var candidateUTF8End: Int?
        /// Set once the scanned text contains something that keeps every
        /// longer prefix unsafe, or after a rejected proposal. No further
        /// boundary is proposed until the pending tail is reset.
        private(set) var isPoisoned = false

        // The parse of a tail is preceded by `inlineParsingSentinel`, which
        // CommonMark classifies as neither whitespace nor punctuation.
        private var previousClass: ScalarClass = .other
        private var previousScalar: Unicode.Scalar?
        private var pendingRun: PendingRun?
        private var codeSpanRunLength: Int?
        private var emphasisOpeners: [DelimiterOpener] = []
        private var bracketScopes: [BracketScope] = []
        private var awaitsLinkDestination = false
        private var linkDestinationDepth = 0
        private var singleQuoteOpeners = 0
        private var doubleQuoteOpeners = 0

        private var isBalanced: Bool {
            pendingRun == nil
                && codeSpanRunLength == nil
                && emphasisOpeners.isEmpty
                && bracketScopes.isEmpty
                && !awaitsLinkDestination
                && linkDestinationDepth == 0
                && singleQuoteOpeners == 0
                && doubleQuoteOpeners == 0
        }

        /// Classifies only the scalars appended since the previous call.
        mutating func scan(_ line: String) {
            let utf8 = line.utf8
            guard !isPoisoned else {
                scannedUTF8Count = utf8.count
                return
            }
            let scalars = line.unicodeScalars
            var index = utf8.index(utf8.startIndex, offsetBy: scannedUTF8Count)
            while index < scalars.endIndex, !isPoisoned {
                let scalar = scalars[index]
                process(scalar, at: scannedUTF8Count)
                scannedUTF8Count += UTF8.width(scalar)
                index = scalars.index(after: index)
            }
            if isPoisoned {
                scannedUTF8Count = utf8.count
            }
        }

        /// Rebases offsets after `utf8Count` bytes were removed from the start
        /// of the pending line.
        mutating func consumePrefix(utf8Count: Int) {
            scannedUTF8Count = max(0, scannedUTF8Count - utf8Count)
            if let candidate = candidateUTF8End, candidate > utf8Count {
                candidateUTF8End = candidate - utf8Count
            } else {
                candidateUTF8End = nil
            }
        }

        mutating func poison() {
            isPoisoned = true
            candidateUTF8End = nil
        }

        private mutating func process(_ scalar: Unicode.Scalar, at offset: Int) {
            let scalarClass = Self.classify(scalar)
            defer {
                previousClass = scalarClass
                previousScalar = scalar
            }
            if var run = pendingRun {
                if scalar == run.marker, run.marker != "'", run.marker != "\"" {
                    run.length += 1
                    pendingRun = run
                    return
                }
                pendingRun = nil
                resolve(run, after: scalarClass)
                guard !isPoisoned else { return }
            }
            if TerminalMarkdownStreamFormatter.closedPrefixFallbackScalars.contains(scalar) {
                isPoisoned = true
                return
            }
            if codeSpanRunLength != nil {
                if scalar == "`" {
                    startRun(scalar)
                }
                return
            }
            if linkDestinationDepth > 0 {
                processLinkDestination(scalar)
                return
            }
            if awaitsLinkDestination {
                awaitsLinkDestination = false
                // Without reference definitions `[text]` alone stays literal.
                guard scalar == "(" else {
                    isPoisoned = true
                    return
                }
                linkDestinationDepth = 1
                return
            }
            switch scalar {
            case "`", "*", "_", "~", "'", "\"":
                startRun(scalar)
            case "[":
                bracketScopes.append(BracketScope(
                    emphasisDepth: emphasisOpeners.count,
                    singleQuoteOpeners: singleQuoteOpeners,
                    doubleQuoteOpeners: doubleQuoteOpeners
                ))
            case "]":
                // Delimiters left open inside link text are dropped as literal
                // text when the link closes; quotes opened there are removed.
                guard let scope = bracketScopes.popLast(),
                      emphasisOpeners.count == scope.emphasisDepth else {
                    isPoisoned = true
                    return
                }
                singleQuoteOpeners = scope.singleQuoteOpeners
                doubleQuoteOpeners = scope.doubleQuoteOpeners
                awaitsLinkDestination = true
            case " ", "\t":
                if offset > 0, previousClass != .whitespace, isBalanced {
                    candidateUTF8End = offset
                }
            default:
                break
            }
        }

        private mutating func processLinkDestination(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "(":
                linkDestinationDepth += 1
            case ")":
                linkDestinationDepth -= 1
            case "`":
                // The strong-marker sanitiser tracks code spans by backtick
                // runs and would see this one as an unterminated opener.
                isPoisoned = true
            default:
                break
            }
        }

        private mutating func startRun(_ marker: Unicode.Scalar) {
            pendingRun = PendingRun(
                marker: marker,
                length: 1,
                before: previousClass,
                beforeScalar: previousScalar
            )
        }

        private mutating func resolve(_ run: PendingRun, after: ScalarClass) {
            if run.marker == "`" {
                if let openLength = codeSpanRunLength {
                    if openLength == run.length {
                        codeSpanRunLength = nil
                    }
                } else {
                    codeSpanRunLength = run.length
                }
                return
            }
            let before = run.before
            let leftFlanking = after != .whitespace
                && (after != .punctuation || before != .other)
            let rightFlanking = before != .whitespace
                && (before != .punctuation || after != .other)
            switch run.marker {
            case "'", "\"":
                let canOpen = leftFlanking && !rightFlanking
                    && run.beforeScalar != "]" && run.beforeScalar != ")"
                resolveQuote(isSingle: run.marker == "'", canOpen: canOpen, canClose: rightFlanking)
            case "_":
                resolveEmphasis(
                    run,
                    canOpen: leftFlanking && (!rightFlanking || before == .punctuation),
                    canClose: rightFlanking && (!leftFlanking || after == .punctuation)
                )
            case "~":
                // GFM strikethrough accepts only runs of one or two tildes.
                guard run.length <= 2 else {
                    isPoisoned = true
                    return
                }
                resolveEmphasis(run, canOpen: leftFlanking, canClose: rightFlanking)
            default:
                resolveEmphasis(run, canOpen: leftFlanking, canClose: rightFlanking)
            }
        }

        /// Smart quotes: an opener without its closer must keep the boundary
        /// closed, because the parser renders it as a right quote until a later
        /// closer turns it into a left quote. Closers inside link text can only
        /// match openers of the same link text.
        private mutating func resolveQuote(isSingle: Bool, canOpen: Bool, canClose: Bool) {
            let scope = bracketScopes.last
            if isSingle {
                if canClose, singleQuoteOpeners > (scope?.singleQuoteOpeners ?? 0) {
                    singleQuoteOpeners -= 1
                } else if canOpen {
                    singleQuoteOpeners += 1
                }
            } else {
                if canClose, doubleQuoteOpeners > (scope?.doubleQuoteOpeners ?? 0) {
                    doubleQuoteOpeners -= 1
                } else if canOpen {
                    doubleQuoteOpeners += 1
                }
            }
        }

        private mutating func resolveEmphasis(
            _ run: PendingRun,
            canOpen: Bool,
            canClose: Bool
        ) {
            var remaining = run.length
            let floor = bracketScopes.last?.emphasisDepth ?? 0
            if canClose {
                while remaining > 0,
                      let index = emphasisOpeners[floor...].lastIndex(where: { $0.marker == run.marker }) {
                    // Unmatched delimiters between an opener and its closer
                    // are left as literal text by the parser.
                    guard index == emphasisOpeners.count - 1 else {
                        isPoisoned = true
                        return
                    }
                    var opener = emphasisOpeners[index]
                    if run.marker == "~" {
                        guard opener.length == remaining else {
                            isPoisoned = true
                            return
                        }
                        emphasisOpeners.removeLast()
                        remaining = 0
                        break
                    }
                    let used = remaining >= 2 && opener.length >= 2 ? 2 : 1
                    opener.length -= used
                    remaining -= used
                    if opener.length == 0 {
                        emphasisOpeners.removeLast()
                    } else {
                        emphasisOpeners[index] = opener
                    }
                }
            }
            guard remaining > 0 else {
                return
            }
            // A run that can neither open nor close (`2 * 3`, `snake_case`)
            // stays literal, so no longer prefix can ever be self-contained.
            guard canOpen else {
                isPoisoned = true
                return
            }
            emphasisOpeners.append(DelimiterOpener(marker: run.marker, length: remaining))
        }

        /// CommonMark's flanking classes as implemented by cmark: Unicode
        /// space separators plus ASCII controls, and ASCII or `P*` punctuation.
        static func classify(_ scalar: Unicode.Scalar) -> ScalarClass {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                return .whitespace
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
                return .punctuation
            case 0...0x7F:
                return .other
            default:
                switch scalar.properties.generalCategory {
                case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                     .initialPunctuation, .finalPunctuation, .otherPunctuation:
                    return .punctuation
                default:
                    return .other
                }
            }
        }
    }
}
