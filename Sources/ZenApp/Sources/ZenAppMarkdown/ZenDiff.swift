//
//  ZenDiff.swift
//  ZenApp
//
//  Unified-diff line classification for code blocks, mirroring the terminal
//  renderer's `TerminalCodeBlockRenderer.DiffState`.
//

import Foundation

/// The role of one line of a unified diff.
public enum ZenDiffLineKind: Equatable, Sendable {
    /// `diff --git`, `index`, `--- a/…`, `+++ b/…`, mode and rename lines.
    case header
    /// `@@ -a,b +c,d @@`
    case hunk
    /// A `+` line.
    case addition
    /// A `-` line.
    case removal
    /// A ` ` context line.
    case context
    /// Anything else (including `\ No newline at end of file`).
    case plain
}

/// One classified diff line.
public struct ZenDiffLine: Equatable, Sendable {
    /// The line role.
    public var kind: ZenDiffLineKind
    /// The line text, without its newline.
    public var text: String

    /// Creates a classified line.
    public init(kind: ZenDiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Unified-diff detection and classification.
public enum ZenDiff {
    /// Whether a fence language marks a diff: `diff`, `patch`, or
    /// `diff-<language>`.
    public static func isDiffLanguage(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else {
            return false
        }
        return language == "diff" || language == "patch" || language.hasPrefix("diff-")
    }

    /// Whether `code` is a unified diff even without a `diff` fence: it has a
    /// `diff --git` line, a well-formed `@@ -a,b +c,d @@` hunk header, or a
    /// `--- ` file header immediately followed by `+++ `.
    public static func looksLikeUnifiedDiff(_ code: String) -> Bool {
        var previousWasOldFileHeader = false
        for line in lines(of: code) {
            if line.hasPrefix("diff --git ") {
                return true
            }
            if line.hasPrefix("@@ "), DiffState.hunkRanges(line) != nil {
                return true
            }
            if previousWasOldFileHeader, line.hasPrefix("+++ ") {
                return true
            }
            previousWasOldFileHeader = line.hasPrefix("--- ")
        }
        return false
    }

    /// Classifies every line of `code`. Hunk line counts are tracked, so
    /// inside a hunk `+++ x` is an addition and `--- x` a removal rather than
    /// file headers.
    public static func classify(_ code: String) -> [ZenDiffLine] {
        var state = DiffState()
        return lines(of: code).map { line in
            ZenDiffLine(kind: state.classify(line), text: line)
        }
    }

    /// The lines of `code`, with `\r\n` and `\r` normalized.
    static func lines(of code: String) -> [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// The hunk-aware classifier state.
    struct DiffState {
        private var oldRemaining = 0
        private var newRemaining = 0

        mutating func classify(_ line: String) -> ZenDiffLineKind {
            if line.hasPrefix("@@") {
                self = DiffState()
                if let ranges = Self.hunkRanges(line) {
                    oldRemaining = ranges.old
                    newRemaining = ranges.new
                }
                return .hunk
            }
            if oldRemaining > 0 || newRemaining > 0 {
                // Diff markers are ASCII bytes, not extended grapheme clusters.
                switch line.utf8.first {
                case 0x2B where newRemaining > 0:
                    newRemaining -= 1
                    return .addition
                case 0x2D where oldRemaining > 0:
                    oldRemaining -= 1
                    return .removal
                case 0x20 where oldRemaining > 0 && newRemaining > 0:
                    oldRemaining -= 1
                    newRemaining -= 1
                    return .context
                case nil where oldRemaining > 0 && newRemaining > 0:
                    // An empty context line whose leading space was trimmed.
                    oldRemaining -= 1
                    newRemaining -= 1
                    return .context
                default:
                    break
                }
            }
            // The no-final-newline annotation does not consume either range.
            if line.hasPrefix("\\ ") {
                return .plain
            }
            // Unknown or inconsistent input ends the hunk.
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

        /// The old and new line counts of a `@@ -a,b +c,d @@` header.
        static func hunkRanges(_ line: String) -> (old: Int, new: Int)? {
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
                  let old = range(parts[1], marker: "-"),
                  let new = range(parts[2], marker: "+") else {
                return nil
            }
            return (old, new)
        }

        private static func range(_ range: Substring, marker: Character) -> Int? {
            guard range.first == marker else {
                return nil
            }
            let parts = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  Int(parts[0]) != nil else {
                return nil
            }
            guard parts.count == 2 else {
                return 1
            }
            return Int(parts[1])
        }
    }
}
