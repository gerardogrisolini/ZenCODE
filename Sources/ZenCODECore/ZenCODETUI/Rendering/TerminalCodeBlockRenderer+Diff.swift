//
//  TerminalCodeBlockRenderer+Diff.swift
//  ZenCODE
//

import Foundation

extension TerminalCodeBlockRenderer {
    enum DiffLineKind {
        case header, hunk, addition, removal, context, plain
    }

    /// Hunk counts distinguish source such as `+++ value` from file headers.
    /// The same state is used by complete Markdown and incremental fences.
    struct DiffState {
        private var oldRemaining = 0
        private var newRemaining = 0

        mutating func classify(_ line: String) -> DiffLineKind {
            if line.hasPrefix("@@") {
                let parts = line.split(separator: " ")
                oldRemaining = parts.count > 2 ? Self.count(parts[1], marker: "-") : 0
                newRemaining = parts.count > 2 ? Self.count(parts[2], marker: "+") : 0
                return .hunk
            }
            if oldRemaining > 0 || newRemaining > 0 {
                switch line.first {
                case "+":
                    newRemaining = max(0, newRemaining - 1)
                    return .addition
                case "-":
                    oldRemaining = max(0, oldRemaining - 1)
                    return .removal
                case " ":
                    oldRemaining = max(0, oldRemaining - 1)
                    newRemaining = max(0, newRemaining - 1)
                    return .context
                default: break // Includes the no-final-newline annotation.
                }
            }
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("rename ") || line.hasPrefix("similarity index")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                oldRemaining = 0
                newRemaining = 0
                return .header
            }
            switch line.first {
            case "+": return .addition
            case "-": return .removal
            case " ": return .context
            default: return .plain
            }
        }

        private static func count(_ range: Substring, marker: Character) -> Int {
            guard range.first == marker else { return 0 }
            let parts = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let first = parts.first, Int(first) != nil else { return 0 }
            return parts.count == 1 ? 1 : max(0, Int(parts[1]) ?? 0)
        }
    }

    /// A single fence token retains both diff semantics and the source language
    /// through CommonMark's language-only API, without changing artifact data.
    static func isDiffLanguage(_ language: String?) -> Bool {
        guard let language = normalizedLanguage(language) else { return false }
        return language == "diff" || language == "patch" || language.hasPrefix("diff-")
    }

    static func diffSourceLanguage(_ language: String?) -> String? {
        guard let language = normalizedLanguage(language), language.hasPrefix("diff-") else {
            return nil
        }
        let source = normalizedLanguage(String(language.dropFirst(5)))
        guard let source, !source.isEmpty, !isDiffLanguage(source) else { return nil }
        return source
    }

    static func diffLineKind(_ line: String) -> DiffLineKind {
        var state = DiffState()
        return state.classify(line)
    }

    static func renderDiffLine(
        _ line: String,
        sourceLanguage: String? = nil,
        kind: DiffLineKind? = nil,
        palette: TerminalMarkdownPalette
    ) -> String {
        let kind = kind ?? diffLineKind(line)
        switch kind {
        case .header:
            return "\(palette.diffHeader)\(terminalSafeSourceLine(line))\(reset)"
        case .hunk:
            return "\(palette.diffHunk)\(terminalSafeSourceLine(line))\(reset)"
        case .plain:
            return terminalSafeSourceLine(line)
        case .addition, .removal, .context:
            // Expand tabs relative to source column zero, not the diff marker.
            let source = String(line.dropFirst())
            let highlighted = sourceLanguage.map {
                renderLine(source, language: $0, palette: palette)
            } ?? terminalSafeSourceLine(source)
            let marker = String(line.prefix(1))
            switch kind {
            case .addition: return "\(palette.diffAddition)\(marker)\(reset)\(highlighted)"
            case .removal: return "\(palette.diffRemoval)\(marker)\(reset)\(highlighted)"
            default: return marker + highlighted
            }
        }
    }
}
