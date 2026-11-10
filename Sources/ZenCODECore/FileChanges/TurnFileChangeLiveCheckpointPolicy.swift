import Foundation
import ToolCore

/// Which tool completions take a live workspace checkpoint
/// (``TurnFileChangeTracker/collectLiveSummary(matching:)``).
///
/// A completion of a core tool that only reads, and reports no file change,
/// skips the checkpoint: it launches no Git process and rereads no file.
/// Every other completion (`local.exec`, writing tools, MCP and feature
/// tools, `agent.*`, `exec.job`, unknown names) takes it as before, and the
/// final summary of the turn always reconciles the whole worktree.
enum TurnFileChangeLiveCheckpointPolicy {
    /// The core tools that only read, by exact name: the read-only Files
    /// tools (`local.pwd`, `local.ls`, `local.readFile`, `local.readFiles`,
    /// `local.inspectFile`), every Search and Text tool, the read-only memory
    /// tools, the prompt-skill tools, `todo.read`, `tasks.list`, and
    /// `tasks.get`. Built from the catalog's read-only descriptors; of the
    /// todo and task ones only the three that read are kept.
    static let readOnlyToolNames: Set<String> = {
        let readingTodoTaskToolNames: Set<String> = ["todo.read", "tasks.list", "tasks.get"]
        let descriptors = DirectToolCatalog.coreReadLocalFileAndTextDescriptors
            + DirectToolCatalog.skillToolDescriptors
            + DirectToolCatalog.coreReadMemoryDescriptors
            + DirectToolCatalog.coreReadTodoTaskDescriptors.filter {
                readingTodoTaskToolNames.contains($0.name)
            }
        return Set(descriptors.map(\.name))
    }()

    /// `true` when the completion of `toolName` with `fileChanges` skips the
    /// live checkpoint. A missing name never skips it.
    static func skipsCheckpoint(toolName: String?, fileChanges: [OperationFileChange]) -> Bool {
        guard let toolName, fileChanges.isEmpty else { return false }
        return readOnlyToolNames.contains(toolName)
    }
}
