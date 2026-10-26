//
//  PatchFileHeaders.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/10/26.
//

import Foundation

/// Recognizes file headers in `local.applyPatch` payloads without taking hunk
/// content for headers: removing `-- note` yields `--- note` and adding
/// `++ x` yields `+++ x`. Unified-diff hunks are tracked through their `@@`
/// counts (the rules of `TerminalCodeBlockRenderer.DiffState`), and Begin Patch
/// sections treat every line as content until the next section marker.
///
/// The rule is shared by the tool presentation, the turn file-change tracker,
/// and the unified-diff applier, so the files shown for a patch are the files
/// the patch actually modifies.
public enum PatchFileHeaders {
    /// Returns the raw, un-normalized header values in payload order: the
    /// trimmed `*** Add/Update/Delete File:` paths and the text after each
    /// `--- ` / `+++ ` pair prefix. Callers apply their own normalization.
    public static func rawPathValues(in patch: String) -> [String] {
        scan(patch).values
    }

    /// Returns the indices, in `patch.components(separatedBy: "\n")`, of the
    /// `--- ` line of every `--- ` / `+++ ` pair recognized as a file header.
    /// Any other line that merely starts with `--- ` is hunk content.
    public static func fileHeaderLineIndices(in patch: String) -> Set<Int> {
        scan(patch).headerLineIndices
    }

    /// The single pass behind both public entry points, so the header rule
    /// lives in one place.
    private struct Scan {
        var values: [String] = []
        var headerLineIndices: Set<Int> = []
    }

    private static func scan(_ patch: String) -> Scan {
        let lines = patch.components(separatedBy: "\n").map(withoutTrailingCarriageReturn)
        var result = Scan()
        var isInSection = false
        var hunk = Hunk.none
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let value = sectionValue(line) {
                if !value.isEmpty {
                    result.values.append(value)
                }
                isInSection = true
                hunk = .none
                index += 1
                continue
            }
            if line == "*** End Patch" {
                isInSection = false
                hunk = .none
                index += 1
                continue
            }
            if isInSection {
                index += 1
                continue
            }
            if hasPrefix(line, "diff --git ") {
                hunk = .none
                index += 1
                continue
            }
            if hasPrefix(line, "@@") {
                hunk = Hunk(header: line)
                index += 1
                continue
            }

            // A file header is a `--- ` line immediately followed by `+++ `.
            // Inside a hunk it also needs a following `@@`, since a hunk body
            // line can never start with `@`. That tolerates wrong LLM counts
            // without losing the next file, except when the pair exactly
            // exhausts a counted hunk: then it is a removal plus an addition.
            if hasPrefix(line, "--- "),
               index + 1 < lines.count,
               hasPrefix(lines[index + 1], "+++ "),
               hunk.allowsFileHeader(
                   followedBy: index + 2 < lines.count ? lines[index + 2] : nil
               ) {
                result.values.append(value(of: line, droppingPrefixOfLength: 4))
                result.values.append(value(of: lines[index + 1], droppingPrefixOfLength: 4))
                result.headerLineIndices.insert(index)
                hunk = .none
                index += 2
                continue
            }

            if hunk.isActive {
                // A counted hunk ends at the first foreign line, which is then
                // evaluated again as part of the header region.
                if hunk.consume(line) {
                    index += 1
                }
            } else {
                index += 1
            }
        }

        return result
    }

    private enum Hunk {
        case none
        /// `@@` without usable ranges, common in LLM-generated patches.
        case uncounted
        case counted(old: Int, new: Int)

        init(header: String) {
            let parts = header.split(separator: " ")
            guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
                  let old = Self.count(parts[1], marker: "-"),
                  let new = Self.count(parts[2], marker: "+") else {
                self = .uncounted
                return
            }
            self = old == 0 && new == 0 ? .none : .counted(old: old, new: new)
        }

        var isActive: Bool {
            if case .none = self { return false }
            return true
        }

        func allowsFileHeader(followedBy next: String?) -> Bool {
            switch self {
            case .none:
                return true
            case .uncounted:
                return next.map { PatchFileHeaders.hasPrefix($0, "@@") } ?? false
            case let .counted(old, new):
                guard let next, PatchFileHeaders.hasPrefix(next, "@@") else {
                    return false
                }
                return !(old == 1 && new == 1)
            }
        }

        /// Consumes a hunk body line. Returns `false` when the line is not body
        /// content; a counted hunk is then closed.
        mutating func consume(_ line: String) -> Bool {
            switch self {
            case .none:
                return false
            case .uncounted:
                return true
            case .counted(var old, var new):
                switch line.utf8.first {
                case 0x2B where new > 0:
                    new -= 1
                case 0x2D where old > 0:
                    old -= 1
                case 0x20 where old > 0 && new > 0, nil where old > 0 && new > 0:
                    old -= 1
                    new -= 1
                case 0x5C:
                    break
                default:
                    self = .none
                    return false
                }
                self = old == 0 && new == 0 ? .none : .counted(old: old, new: new)
                return true
            }
        }

        private static func count(_ range: Substring, marker: Character) -> Int? {
            guard range.first == marker else { return nil }
            let parts = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            }), let start = Int(parts[0]) else { return nil }
            let count = parts.count == 2 ? Int(parts[1]) : 1
            guard let count,
                  count == 0 || (start > 0 && !start.addingReportingOverflow(count - 1).overflow) else {
                return nil
            }
            return count
        }
    }

    private static let sectionPrefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: "]

    /// The trimmed path of a Begin Patch section line, or `nil` for other lines.
    private static func sectionValue(_ line: String) -> String? {
        guard let prefix = sectionPrefixes.first(where: { hasPrefix(line, $0) }) else {
            return nil
        }
        return value(of: line, droppingPrefixOfLength: prefix.utf8.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diff markers are ASCII bytes, so prefixes are compared on UTF-8 rather
    /// than on extended grapheme clusters.
    private static func hasPrefix(_ line: String, _ prefix: String) -> Bool {
        line.utf8.starts(with: prefix.utf8)
    }

    private static func value(of line: String, droppingPrefixOfLength length: Int) -> String {
        String(decoding: line.utf8.dropFirst(length), as: UTF8.self)
    }

    private static func withoutTrailingCarriageReturn(_ line: String) -> String {
        guard line.utf8.last == 0x0D else { return line }
        return String(decoding: line.utf8.dropLast(), as: UTF8.self)
    }
}
