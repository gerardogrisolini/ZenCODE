import Foundation
import ToolCore

extension TurnFileChangeTracker {
    /// A workspace checkpoint, not operation-attributed evidence. Callers serialize
    /// collection and publication, and drain them before final reconciliation.
    func collectLiveSummary(matching changes: [OperationFileChange]) async -> TurnFileChangeSummary? {
        guard !didFinalizeSummary else { return nil }
        #if canImport(Darwin) || canImport(Glibc)
        await reconcileWorktreeChangesIfNeeded()
        #endif
        guard !didFinalizeSummary else { return nil }
        let directChanges = Dictionary(changes.map {
            (FileChangeArtifactMapper.absolutePath(for: $0.path, workingDirectory: baseDirectoryURL), $0)
        }, uniquingKeysWith: { first, _ in first })
        var entries: [TurnFileChangeSummary.Entry] = []
        for baseline in snapshotsByPath.values.sorted(by: { $0.displayPath < $1.displayPath }) {
            let previous = liveSnapshotsByPath[baseline.absolutePath] ?? baseline
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: baseline.absolutePath, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            let data = exists ? try? Data(contentsOf: URL(fileURLWithPath: baseline.absolutePath)) : nil
            guard !exists || data != nil else { continue }
            let current = Snapshot(
                absolutePath: baseline.absolutePath, displayPath: baseline.displayPath,
                beforeData: data, existedInitially: exists
            )
            liveSnapshotsByPath[baseline.absolutePath] = current
            guard previous.existedInitially != exists || previous.beforeData != data else { continue }
            if let direct = directChanges[baseline.absolutePath], direct.explanation == nil {
                if let text = direct.newText, exists, data == Data(text.utf8) { continue }
                if direct.newText == nil, direct.oldText != nil, !exists { continue }
            }
            entries.append(await summaryEntry(for: previous, afterData: data, existsNow: exists))
        }
        return entries.isEmpty ? nil : TurnFileChangeSummary(entries: entries)
    }
}
