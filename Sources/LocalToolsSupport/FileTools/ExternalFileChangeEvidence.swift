import Foundation
import ToolCore

/// Records file-change evidence captured outside this process, such as the
/// before/after images reported by a feature whose tools write through an
/// application's MCP server. It applies the same byte limits, binary handling,
/// and compact-diff fallback as local writes; the producer, not the host
/// mutation lock, is responsible for the certainty of the captured images.
public enum ExternalFileChangeEvidence {
    /// Upper bound of entries accepted from one external operation.
    public static let maximumChanges = 64
    /// Upper bound of a producer-supplied explanation.
    public static let maximumExplanationLength = 512

    public static func record(
        path: URL,
        oldText: String?,
        newText: String?,
        explanation: String?
    ) {
        guard let recorder = OperationFileChangeRecorder.current else { return }
        let standardizedPath = path.standardizedFileURL.path
        if let explanation {
            recorder.record(OperationFileChange(
                path: standardizedPath,
                oldText: nil,
                newText: nil,
                explanation: String(explanation.prefix(maximumExplanationLength))
            ))
            return
        }
        guard oldText != nil || newText != nil else {
            recorder.record(OperationFileChange(
                path: standardizedPath,
                oldText: nil,
                newText: nil,
                explanation: "Diff unavailable: the change evidence is incomplete."
            ))
            return
        }
        let before = oldText.map { Data($0.utf8) }
        guard (before?.count ?? 0) <= OperationFileChangeRecorder.maximumSnapshotBytes,
              (newText?.utf8.count ?? 0) <= OperationFileChangeRecorder.maximumSnapshotBytes else {
            recorder.record(OperationFileChange(
                path: standardizedPath,
                oldText: nil,
                newText: nil,
                explanation: "Diff unavailable: file or operation evidence exceeds the byte limit."
            ))
            return
        }
        LocalOperationWrite.recordEvidence(
            recorder: recorder,
            path: path,
            existed: oldText != nil,
            before: before,
            after: newText
        )
    }
}
