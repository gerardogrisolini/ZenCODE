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
    /// Source positions are meaningful only inside a valid, unexhausted hunk.
    /// The same state is used by artifact numbering and both Markdown renderers.
    struct DiffState {
        private var oldRemaining = 0
        private var newRemaining = 0
        private var oldLine = 0
        private var newLine = 0
        private(set) var sourceLineNumber: Int?

        mutating func classify(_ line: String) -> DiffLineKind {
            sourceLineNumber = nil
            if line.hasPrefix("@@") {
                self = DiffState()
                let parts = line.split(separator: " ")
                if parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
                   let old = Self.range(parts[1], marker: "-"),
                   let new = Self.range(parts[2], marker: "+") {
                    oldLine = old.start
                    newLine = new.start
                    oldRemaining = old.count
                    newRemaining = new.count
                }
                return .hunk
            }
            if oldRemaining > 0 || newRemaining > 0 {
                // Diff markers are ASCII bytes, not extended grapheme clusters.
                switch line.utf8.first {
                case 0x2B where newRemaining > 0:
                    sourceLineNumber = newLine
                    newRemaining -= 1
                    if newRemaining > 0 { newLine += 1 }
                    return .addition
                case 0x2D where oldRemaining > 0:
                    sourceLineNumber = oldLine
                    oldRemaining -= 1
                    if oldRemaining > 0 { oldLine += 1 }
                    return .removal
                case 0x20 where oldRemaining > 0 && newRemaining > 0:
                    sourceLineNumber = newLine
                    oldRemaining -= 1
                    newRemaining -= 1
                    if oldRemaining > 0 { oldLine += 1 }
                    if newRemaining > 0 { newLine += 1 }
                    return .context
                default: break
                }
            }
            // The no-final-newline annotation does not consume either range.
            if line.hasPrefix("\\ ") { return .plain }
            // Unknown/inconsistent input cannot carry source positions forward.
            oldRemaining = 0
            newRemaining = 0
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("rename ") || line.hasPrefix("similarity index")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                return .header
            }
            switch line.utf8.first {
            case 0x2B: return .addition
            case 0x2D: return .removal
            case 0x20: return .context
            default: return .plain
            }
        }

        private static func range(_ range: Substring, marker: Character) -> (start: Int, count: Int)? {
            guard range.first == marker else { return nil }
            let parts = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            }), let start = Int(parts[0]) else { return nil }
            let count: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]) else { return nil }
                count = parsed
            } else {
                count = 1
            }
            guard count == 0 || (start > 0 && !start.addingReportingOverflow(count - 1).overflow) else {
                return nil
            }
            return (start, count)
        }
    }

    /// Only the transient artifact Markdown carries a gutter. Ordinary `diff`,
    /// `patch`, and source-code fences retain their existing presentation.
    static func isArtifactDiffLanguage(_ language: String?) -> Bool {
        guard let language = normalizedLanguage(language) else { return false }
        return language == "artifact-diff" || language.hasPrefix("artifact-diff-")
    }

    static func numberedArtifactDiff(_ diff: String) -> String {
        let normalized = diff.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let content = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized
        var state = DiffState()
        let rows = content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            _ = state.classify(String(line))
            return (source: String(line), number: state.sourceLineNumber.map(String.init) ?? "")
        }
        let digits = max(1, rows.map { $0.number.count }.max() ?? 0)
        return rows.map { row in
            String(repeating: " ", count: digits - row.number.count) + row.number + " │ " + row.source
        }.joined(separator: "\n")
    }

    static func artifactDiffRow(_ line: String, language: String?) -> (gutter: String, source: String)? {
        guard isArtifactDiffLanguage(language), let separator = line.range(of: " │ ") else {
            return nil
        }
        let number = line[..<separator.lowerBound]
        guard !number.isEmpty, number.utf8.allSatisfy({ $0 == 32 || (48...57).contains($0) }) else {
            return nil
        }
        return (String(line[..<separator.upperBound]), String(line[separator.upperBound...]))
    }

    static func diffSourceLine(_ line: String, language: String?) -> String {
        artifactDiffRow(line, language: language)?.source ?? line
    }

    /// A single fence token retains both diff semantics and the source language
    /// through CommonMark's language-only API, without changing artifact data.
    static func isDiffLanguage(_ language: String?) -> Bool {
        guard let language = normalizedLanguage(language) else { return false }
        return language == "diff" || language == "patch" || language.hasPrefix("diff-")
            || isArtifactDiffLanguage(language)
    }

    static func diffSourceLanguage(_ language: String?) -> String? {
        guard var language = normalizedLanguage(language) else { return nil }
        if isArtifactDiffLanguage(language) { language = String(language.dropFirst(9)) }
        guard language.hasPrefix("diff-") else { return nil }
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
            // Remove only the ASCII scalar; combining source scalars must stay.
            let source = String(line.unicodeScalars.dropFirst())
            let highlighted = sourceLanguage.map {
                renderLine(source, language: $0, palette: palette)
            } ?? terminalSafeSourceLine(source)
            let marker = String(line.unicodeScalars.prefix(1))
            switch kind {
            case .addition: return "\(palette.diffAddition)\(marker)\(reset)\(highlighted)"
            case .removal: return "\(palette.diffRemoval)\(marker)\(reset)\(highlighted)"
            default: return marker + highlighted
            }
        }
    }
}
