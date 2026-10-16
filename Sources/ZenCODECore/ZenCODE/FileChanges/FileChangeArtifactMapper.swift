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
            let evidence = boundedEvidence(
                oldText: boundedText(base64: entry.beforeDataBase64),
                newText: nil, patch: entry.patch,
                status: status, isBinary: entry.isBinary, explanation: nil, budget: &budget
            )
            return FileChangeArtifact(
                absolutePath: path, displayPath: displayPath(for: path, workingDirectory: workingDirectory),
                status: status, additions: entry.additions, deletions: entry.deletions,
                hasLineCounts: !evidence.binary && (evidence.explanation == nil || entry.additions > 0 || entry.deletions > 0),
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
