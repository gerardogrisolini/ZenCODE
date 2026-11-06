//
//  ZenCODESetupRunner+DataManagement.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Created by ZenCODE on 2026-08-24.
//

import Foundation

/// The "Data management" subsection of the setup menu.
///
/// Groups the whole-directory transfer lifecycle — export to a single
/// compressed archive, import with full validation, and the existing remote
/// configuration reset — behind one clearly named entry point. Every action
/// states the exact paths it touches and the sensitive nature of the data,
/// and cancelling any prompt leaves the support directory untouched.
extension ZenCODESetupRunner {
    enum DataManagementAction: Equatable {
        case export
        case importBackup
        case cleanMemory
        case cleanSupportDirectory
        case rebuildEmbeddings
        case reset
        case back
    }

    /// Terminal outcome of the data management submenu.
    enum DataManagementOutcome: Equatable {
        /// An export completed; the operator stayed in the submenu flow.
        case exportCompleted
        /// The remote configuration was reset.
        case reset
        /// The support directory was replaced by an imported backup.
        case dataReplaced
        /// The operator returned to the main setup menu.
        case back
    }

    /// Builds the submenu items; pure so tests can assert the structure
    /// without a terminal.
    static func dataManagementMenuItems() -> [TerminalCheckboxMenuItem<DataManagementAction>] {
        [
            TerminalCheckboxMenuItem(
                value: .export,
                title: "Export backup",
                detail: "write the whole support directory to one compressed archive"
            ),
            TerminalCheckboxMenuItem(
                value: .importBackup,
                title: "Import backup",
                detail: "replace the support directory with a validated archive"
            ),
            TerminalCheckboxMenuItem(
                value: .cleanMemory,
                title: "Clean memory",
                detail: "preview and clean a memory graph, or delete an old project's memory"
            ),
            TerminalCheckboxMenuItem(
                value: .cleanSupportDirectory,
                title: "Clean support directory",
                detail: "free disk space: delete browser caches and build files that are regenerated"
            ),
            TerminalCheckboxMenuItem(
                value: .rebuildEmbeddings,
                title: "Rebuild memory embeddings",
                detail: "embed entries missing a vector from the configured model, in every memory graph"
            ),
            TerminalCheckboxMenuItem(
                value: .reset,
                title: "Reset remote configuration",
                detail: "remove provider settings and ZenCODE support files"
            ),
            TerminalCheckboxMenuItem(
                value: .back,
                title: "Back",
                detail: "return to the main setup menu"
            )
        ]
    }

    /// The single-select submenu presented when the operator chooses
    /// "Data management". Returns `nil` when the operator goes back with Esc.
    static func promptDataManagementAction(
        selectOne: (
            String,
            [TerminalCheckboxMenuItem<DataManagementAction>],
            DataManagementAction
        ) -> DataManagementAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) -> DataManagementAction? {
        selectOne("Data management", dataManagementMenuItems(), .export)
    }

    /// Runs the data management submenu until the operator leaves it.
    ///
    /// Esc on the submenu, like Back, returns to the main setup menu. Esc
    /// inside an action prints a message and opens the submenu again with the
    /// data untouched. Another error the action raises is printed and the
    /// submenu opens again as well, but the action may have been partly
    /// applied, for example a memory folder deletion that stopped half way
    /// (see ``runningDataManagementAction(_:write:_:)``). Only a
    /// `CancellationError` (or any error once the task is cancelled) and a
    /// failure of the reset itself propagate: a failed reset may leave a
    /// partially removed configuration, so setup must not go on to a Finish
    /// that rewrites the settings.
    ///
    /// `promptAction` and `importBackup` replace the terminal menu and the
    /// import prompts in tests.
    @discardableResult
    static func runDataManagementMenu(
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        promptAction: () -> DataManagementAction? = { promptDataManagementAction() },
        importBackup: () throws -> Bool = { try runDataImport() }
    ) async throws -> DataManagementOutcome {
        while true {
            guard let action = promptAction() else {
                return .back
            }
            switch action {
            case .export:
                try await runningDataManagementAction("Export", write: write) {
                    try runDataExport()
                }
            case .importBackup:
                let imported = try await runningDataManagementAction("Import", write: write) {
                    try importBackup()
                }
                if imported == true {
                    // An imported backup may predate settings v15: migrate it
                    // to provider keys before setup reads it again.
                    AgentProviderKeyMigration.migrateIfNeededReportingFailures()
                    await MemoryGraphStoreRegistry.shared.reset()
                    return .dataReplaced
                }
            case .cleanMemory:
                try await runningDataManagementAction("Clean memory", write: write) {
                    try await runMemoryCleanupMenu()
                }
            case .cleanSupportDirectory:
                try await runningDataManagementAction("Clean support directory", write: write) {
                    try runSupportDirectoryCleanup()
                }
            case .rebuildEmbeddings:
                await runMemoryReembeddingFromDataManagement()
            case .reset:
                let confirmed = try await runningDataManagementAction("Reset", write: write) {
                    try confirmRemoteConfigurationReset()
                }
                guard confirmed == true else {
                    continue
                }
                // Deliberately outside `runningDataManagementAction`: see the
                // note on the reset failure above.
                try resetRemoteConfiguration()
                await MemoryGraphStoreRegistry.shared.reset()
                return .reset
            case .back:
                return .back
            }
        }
    }

    /// Runs one Data management action. Esc on one of its prompts
    /// (`ZenCODESetupError.cancelled`) writes "<action> cancelled." and any
    /// other error "<action> failed: <description>"; both return `nil`, so
    /// the submenu opens again instead of leaving setup and dropping its
    /// unsaved changes. After Esc the data is untouched; after a failure the
    /// action may have been partly applied (for example a memory folder
    /// deletion that stopped half way). A `CancellationError`, or any error
    /// once the task is cancelled, propagates.
    @discardableResult
    static func runningDataManagementAction<Value>(
        _ actionTitle: String,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        _ body: () async throws -> Value
    ) async throws -> Value? {
        do {
            return try await body()
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            if case ZenCODESetupError.cancelled? = error as? ZenCODESetupError {
                write("\(actionTitle) cancelled.\n\n")
            } else {
                write("\(actionTitle) failed: \(error.localizedDescription)\n\n")
            }
            return nil
        }
    }

    // MARK: - Export

    /// Prompts for a destination and writes the support directory archive.
    ///
    /// The prompt names the source directory explicitly and warns that the
    /// archive contains credentials in plain text.
    static func runDataExport(
        fileManager: FileManager = .default
    ) throws {
        let supportDirectoryURL = ZenFileService.supportDirectoryURL(
            fileManager: fileManager
        )
        AgentOutput.standardError.writeString(
            """
            Export writes every file under:
            \(supportDirectoryURL.path)
            The archive contains provider credentials and is not encrypted.

            """
        )
        let defaultArchiveURL = defaultExportArchiveURL(
            supportDirectoryURL: supportDirectoryURL
        )
        let archivePath = try promptString(
            "Archive path",
            defaultValue: defaultArchiveURL.path,
            allowEmpty: false,
            help: "Destination file. An existing archive is kept unless the new export completes and is published safely."
        )
        let archiveURL = URL(
            fileURLWithPath: (archivePath as NSString).expandingTildeInPath
        )

        guard try confirmOverwriteIfExisting(archiveURL, fileManager: fileManager) else {
            AgentOutput.standardError.writeString("Export cancelled.\n\n")
            return
        }
        let result = try SupportDirectoryArchive.exportReplacingExisting(
            from: supportDirectoryURL,
            to: archiveURL,
            fileManager: fileManager
        )
        printDataExportResult(result)
    }

    /// `~/Downloads` when available, otherwise the parent of the support
    /// directory, so the default never suggests writing inside the directory
    /// being archived.
    private static func defaultExportArchiveURL(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let downloadsURL = fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        let baseDirectoryURL = downloadsURL
            ?? supportDirectoryURL.deletingLastPathComponent()
        return baseDirectoryURL.appendingPathComponent(
            SupportDirectoryArchive.defaultArchiveFilename,
            isDirectory: false
        )
    }

    private static func confirmOverwriteIfExisting(
        _ archiveURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            return true
        }
        return try promptYesNo(
            "Overwrite the existing file at \(archiveURL.path)?",
            defaultValue: false,
            help: "The existing archive is kept untouched unless the new export succeeds."
        )
    }

    private static func printDataExportResult(
        _ result: SupportDirectoryArchive.ExportResult
    ) {
        AgentOutput.standardError.writeString(
            """

            Backup exported:
              File: \(result.archiveURL.path)
              Files: \(result.fileCount)
              Size (uncompressed): \(result.totalBytes) bytes

            Keep the archive private: it contains API keys and tokens.

            """
        )
    }

    // MARK: - Import

    /// Prompts for an archive and replaces the support directory with its
    /// validated content.
    ///
    /// - Returns: `true` when the import succeeded and the imported data
    ///   replaced the current configuration.
    static func runDataImport(
        fileManager: FileManager = .default
    ) throws -> Bool {
        let supportDirectoryURL = ZenFileService.supportDirectoryURL(
            fileManager: fileManager
        )
        AgentOutput.standardError.writeString(
            """
            Import replaces every file under:
            \(supportDirectoryURL.path)
            The current content is discarded after the archive is validated.

            """
        )
        let archivePath = try promptString(
            "Archive path",
            defaultValue: nil,
            allowEmpty: false,
            help: "Path to a zencode-backup archive created by Export."
        )
        let archiveURL = URL(
            fileURLWithPath: (archivePath as NSString).expandingTildeInPath
        )

        // Validate before asking to commit: a malformed archive must never
        // reach the destructive confirmation.
        let manifest = try SupportDirectoryArchive.validate(
            archiveURL: archiveURL,
            fileManager: fileManager
        )
        let totalBytes = manifest.entries.reduce(0) { $0 + $1.size }
        guard try promptYesNo(
            "Replace the current data with this backup?",
            defaultValue: false,
            help: """
                The backup contains \(manifest.entries.count) files \
                (\(totalBytes) bytes uncompressed). Importing replaces every \
                file under the support directory. Cancel now to keep the \
                current data unchanged.
                """
        ) else {
            AgentOutput.standardError.writeString("Import cancelled.\n\n")
            return false
        }

        let result = try SupportDirectoryArchive.import(
            from: archiveURL,
            into: supportDirectoryURL,
            fileManager: fileManager
        )
        printDataImportResult(result)
        return true
    }

    private static func printDataImportResult(
        _ result: SupportDirectoryArchive.ImportResult
    ) {
        AgentOutput.standardError.writeString(
            """

            Backup imported:
              Files: \(result.fileCount)
              Size (uncompressed): \(result.totalBytes) bytes

            """
        )
    }
}
