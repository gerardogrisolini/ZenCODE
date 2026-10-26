//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import ToolCore

/// Shared path, ordering and bounded-evidence policy for TUI and ACP.
/// Mapping never re-reads the worktree: evidence must describe the captured turn.
public enum FileChangeArtifactMapper {
    public static let unavailableEvidenceExplanation =
        "Diff unavailable: text evidence is binary, uncertain, or outside the evidence byte limit."
    public static let binaryExplanation = "Diff unavailable: binary file evidence."
    public static let byteLimitExplanation =
        "Diff unavailable: file or operation evidence exceeds the byte limit."

    /// Shown with the leading part of a workspace-checkpoint patch that exceeds the byte limit.
    /// Counts are diff body lines (context, added and removed), not file lines.
    public static func truncatedPatchExplanation(shown: Int, total: Int) -> String {
        "Diff truncated: showing the first \(shown) of \(total) diff lines; file or operation evidence exceeds the byte limit."
    }

    public static func artifacts(
        from changes: [OperationFileChange],
        workingDirectory: URL?
    ) -> [FileChangeArtifact] {
        var budget = OperationFileChangeRecorder.maximumOperationBytes
        var seen = Set<String>()
        return changes.compactMap { change in
            guard !change.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let path = absolutePath(for: change.path, workingDirectory: workingDirectory)
            guard seen.insert(path).inserted else { return nil }
            let status: FileChangeArtifact.Status
            if change.explanation != nil { status = .unknown }
            else if change.compactDiff != nil { status = .modified }
            else {
                switch (change.oldText, change.newText) {
                case (nil, nil): status = .unknown
                case (nil, _): status = .added
                case (_, nil): status = .deleted
                case (_, _): status = .modified
                }
            }
            let evidence = boundedEvidence(
                oldText: change.oldText, newText: change.newText, patch: change.compactDiff?.patch,
                status: status, isBinary: false, explanation: change.explanation,
                allowsEmptyPatch: change.compactDiff != nil, budget: &budget
            )
            let counts: (additions: Int, deletions: Int)
            if evidence.patch != nil, let compact = change.compactDiff {
                counts = (compact.additions, compact.deletions)
            } else {
                counts = lineCounts(old: evidence.old, new: evidence.new)
            }
            return FileChangeArtifact(
                absolutePath: path, displayPath: displayPath(for: path, workingDirectory: workingDirectory),
                status: status, additions: counts.additions, deletions: counts.deletions,
                hasLineCounts: evidence.explanation == nil,
                isBinary: evidence.binary, oldText: evidence.old, newText: evidence.new,
                patch: evidence.patch, explanation: evidence.explanation
            )
        }
    }

    public static func artifacts(
        from summary: TurnFileChangeSummary,
        workingDirectory: URL
    ) -> [FileChangeArtifact] {
        var budget = OperationFileChangeRecorder.maximumOperationBytes
        var seen = Set<String>()
        return summary.entries.compactMap { entry in
            guard !entry.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let path = absolutePath(for: entry.path, workingDirectory: workingDirectory)
            guard seen.insert(path).inserted else { return nil }
            let status = FileChangeArtifact.Status(rawValue: entry.status.rawValue) ?? .unknown
            var evidence = boundedEvidence(
                oldText: boundedText(base64: entry.beforeDataBase64),
                newText: nil, patch: entry.patch,
                status: status, isBinary: entry.isBinary, explanation: nil, budget: &budget
            )
            // Only the artifact is truncated: the summary keeps the full patch for undo and review.
            let allowance = min(OperationFileChangeRecorder.maximumTextBytes, budget)
            if status == .added || status == .deleted || status == .modified,
               !evidence.binary, evidence.explanation == byteLimitExplanation,
               let patch = entry.patch, patch.utf8.count > allowance,
               let truncated = truncatedPatch(patch, maximumBytes: allowance) {
                budget -= truncated.patch.utf8.count
                evidence = Evidence(
                    patch: truncated.patch,
                    explanation: truncatedPatchExplanation(shown: truncated.shown, total: truncated.total)
                )
            }
            return FileChangeArtifact(
                absolutePath: path, displayPath: displayPath(for: path, workingDirectory: workingDirectory),
                status: status, additions: entry.additions, deletions: entry.deletions,
                hasLineCounts: !evidence.binary
                    && (evidence.explanation == nil || evidence.patch != nil || entry.additions > 0 || entry.deletions > 0),
                isBinary: evidence.binary, oldText: evidence.old, newText: evidence.new,
                patch: evidence.patch, explanation: evidence.explanation
            )
        }
    }

    public static func absolutePath(for rawPath: String, workingDirectory: URL?) -> String {
        let expanded = NSString(string: rawPath.trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let base = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    public static func displayPath(for absolutePath: String, workingDirectory: URL?) -> String {
        let absolute = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard let workingDirectory else { return absolute }
        let base = workingDirectory.standardizedFileURL.path
        let prefix = base == "/" ? "/" : base + "/"
        if absolute == base { return "." }
        guard absolute.hasPrefix(prefix) else { return absolute }
        return String(absolute.dropFirst(prefix.count))
    }

    private struct Evidence {
        var old: String?
        var new: String?
        var patch: String?
        var binary = false
        var explanation: String?
    }

    private static func boundedEvidence(
        oldText: String?, newText: String?, patch: String?,
        status: FileChangeArtifact.Status, isBinary: Bool, explanation: String?,
        allowsEmptyPatch: Bool = false, budget: inout Int
    ) -> Evidence {
        let binary = isBinary || oldText?.contains("\0") == true || newText?.contains("\0") == true
            || patch?.contains("\0") == true
        if let explanation { return Evidence(binary: binary, explanation: explanation) }
        if binary { return Evidence(binary: true, explanation: binaryExplanation) }
        // Missing text is not an empty file. Only added/deleted states establish
        // absence; a partially captured modification must use its patch instead.
        let complete: Bool
        switch status {
        case .added: complete = newText != nil
        case .deleted: complete = oldText != nil
        case .modified: complete = oldText != nil && newText != nil
        case .unknown: complete = false
        }
        let oldBytes = oldText?.utf8.count ?? 0
        let newBytes = newText?.utf8.count ?? 0
        let limit = OperationFileChangeRecorder.maximumTextBytes
        if complete, oldBytes <= limit, newBytes <= limit, oldBytes + newBytes <= budget {
            budget -= oldBytes + newBytes
            return Evidence(old: oldText, new: newText)
        }
        if let patch, allowsEmptyPatch || !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           patch.utf8.count <= limit, patch.utf8.count <= budget {
            budget -= patch.utf8.count
            return Evidence(patch: patch)
        }
        let overLimit = oldBytes > limit || newBytes > limit || oldBytes + newBytes > budget
            || (patch?.utf8.count ?? 0) > min(limit, budget)
        return Evidence(explanation: overLimit ? byteLimitExplanation : unavailableEvidenceExplanation)
    }

    /// Keeps the leading part of a single-file git patch that fits in `maximumBytes`.
    ///
    /// File header lines (everything before the first `@@`) stay verbatim, then come the hunks
    /// that fit whole. The first hunk that does not fit keeps the longest prefix of whole body
    /// lines, with its header rewritten to the kept counts, and nothing follows it. Returns nil
    /// for any other shape (unparsable hunk header, foreign or blank body line, no hunk, no
    /// body line that fits) so the byte-limit fallback applies. `shown` and `total` count body
    /// lines starting with a space, `+` or `-`; `\ No newline` markers are not counted.
    private static func truncatedPatch(
        _ patch: String, maximumBytes: Int
    ) -> (patch: String, shown: Int, total: Int)? {
        guard maximumBytes > 0 else { return nil }
        // Work on bytes: Swift treats "\r\n" as one Character, so String splitting is unsafe.
        let bytes = Array(patch.utf8)
        func lineEnd(_ start: Int) -> Int { bytes[start...].firstIndex(of: 0x0A) ?? bytes.count }
        func isHunkHeader(_ start: Int) -> Bool { bytes[start...].starts(with: "@@".utf8) }

        var headerEnd = 0
        while headerEnd < bytes.count, !isHunkHeader(headerEnd) {
            headerEnd = lineEnd(headerEnd) + 1
        }
        guard headerEnd < bytes.count else { return nil }

        var output = Array(bytes[..<headerEnd])
        var shown = 0
        var total = 0
        var stopped = false
        var cursor = headerEnd
        while cursor < bytes.count {
            let headerLineEnd = lineEnd(cursor)
            guard let header = parseHunkHeader(bytes[cursor..<headerLineEnd]) else { return nil }
            let bodyStart = min(headerLineEnd + 1, bytes.count)

            // Validate the whole patch and count its body lines, even after the cut.
            var hunkEnd = bodyStart
            var hunkLines = 0
            var markerAllowed = false // a marker annotates the body line right before it
            while hunkEnd < bytes.count, !isHunkHeader(hunkEnd) {
                let end = lineEnd(hunkEnd)
                guard end > hunkEnd else { return nil }
                switch bytes[hunkEnd] {
                case 0x20, 0x2B, 0x2D:
                    hunkLines += 1
                    markerAllowed = true
                case 0x5C:
                    guard markerAllowed else { return nil }
                    markerAllowed = false
                default:
                    return nil
                }
                hunkEnd = min(end + 1, bytes.count)
            }
            total += hunkLines
            let hunkStart = cursor
            cursor = hunkEnd
            guard !stopped else { continue }

            let needsNewline = bytes[hunkEnd - 1] != 0x0A
            if output.count + (hunkEnd - hunkStart) + (needsNewline ? 1 : 0) <= maximumBytes {
                output.append(contentsOf: bytes[hunkStart..<hunkEnd])
                if needsNewline { output.append(0x0A) }
                shown += hunkLines
                continue
            }

            // First hunk that does not fit: grow the prefix while the rewritten header,
            // whose size depends on the kept counts, and the kept lines still fit.
            stopped = true
            var oldKept = 0
            var newKept = 0
            var keptLines = 0
            var keptEnd = bodyStart
            var keptHeader: [UInt8]?
            var scan = bodyStart
            while scan < hunkEnd {
                let end = lineEnd(scan)
                var old = oldKept
                var new = newKept
                var counted = 0
                switch bytes[scan] {
                case 0x20: old += 1; new += 1; counted = 1
                case 0x2B: new += 1; counted = 1
                case 0x2D: old += 1; counted = 1
                default: break
                }
                let rewritten = header.rewritten(oldKept: old, newKept: new)
                let lineBytes = min(end + 1, bytes.count) - bodyStart
                // Header, its newline, the kept lines, and a newline the last line may lack.
                let candidate = output.count + rewritten.count + 1 + lineBytes
                    + (end >= bytes.count ? 1 : 0)
                guard candidate <= maximumBytes else { break }
                oldKept = old
                newKept = new
                keptLines += counted
                keptEnd = min(end + 1, bytes.count)
                keptHeader = rewritten
                scan = keptEnd
            }
            guard let keptHeader, keptLines > 0 else { continue }
            output.append(contentsOf: keptHeader)
            output.append(0x0A)
            output.append(contentsOf: bytes[bodyStart..<keptEnd])
            if output.last != 0x0A { output.append(0x0A) }
            shown += keptLines
        }
        guard shown >= 1 else { return nil }
        return (String(decoding: output, as: UTF8.self), shown, total)
    }

    /// A parsed `@@ -a[,b] +c[,d] @@[ section]` line. Omitted counts mean one.
    private struct HunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        /// Everything after the closing `@@`, including its leading space; may be empty.
        var section: ArraySlice<UInt8>

        /// The header (without line terminator) for a prefix keeping the given line counts.
        /// Counts are always explicit. A side that loses all its lines moves to the preceding
        /// line, the unified-diff convention for an empty range (so `-1,5` becomes `-0,0`).
        func rewritten(oldKept: Int, newKept: Int) -> [UInt8] {
            let oldFirst = oldKept == 0 && oldCount > 0 ? max(oldStart - 1, 0) : oldStart
            let newFirst = newKept == 0 && newCount > 0 ? max(newStart - 1, 0) : newStart
            return Array("@@ -\(oldFirst),\(oldKept) +\(newFirst),\(newKept) @@".utf8) + section
        }
    }

    private static func parseHunkHeader(_ line: ArraySlice<UInt8>) -> HunkHeader? {
        var index = line.startIndex
        func consume(_ literal: StaticString) -> Bool {
            let expected = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
            guard line[index...].starts(with: expected) else { return false }
            index += expected.count
            return true
        }
        func number() -> Int? {
            let first = index
            while index < line.endIndex, (48...57).contains(line[index]) { index += 1 }
            // Nine digits cannot overflow, and no real hunk comes close.
            guard index > first, index - first <= 9 else { return nil }
            return line[first..<index].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        func range() -> (start: Int, count: Int)? {
            guard let start = number() else { return nil }
            guard index < line.endIndex, line[index] == 0x2C else { return (start, 1) }
            index += 1
            guard let count = number() else { return nil }
            return (start, count)
        }
        guard consume("@@ -"), let old = range(), consume(" +"), let new = range(), consume(" @@"),
              index == line.endIndex || line[index] == 0x20 else { return nil }
        return HunkHeader(
            oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
            section: line[index...]
        )
    }

    private static func boundedText(base64: String?) -> String? {
        // Check encoded size before allocating an unbounded decoded snapshot.
        let limit = OperationFileChangeRecorder.maximumTextBytes
        guard let base64, base64.utf8.count <= ((limit + 2) / 3) * 4,
              let data = Data(base64Encoded: base64), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lineCounts(old: String?, new: String?) -> (additions: Int, deletions: Int) {
        func lines(_ text: String?) -> [String] {
            guard let text, !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { result.removeLast() }
            return result
        }
        var additions = 0
        var deletions = 0
        for change in lines(new).difference(from: lines(old)) {
            switch change {
            case .insert: additions += 1
            case .remove: deletions += 1
            }
        }
        return (additions, deletions)
    }
}
