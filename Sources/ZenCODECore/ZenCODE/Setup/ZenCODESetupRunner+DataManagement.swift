//
//  ZenCODESetupRunner+DataManagement.swift
//  ZenCODE
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
    /// "Data management". Returns `nil` when the operator goes back.
    static func promptDataManagementAction() throws -> DataManagementAction? {
        try promptMenuChoice(
            title: "Data management",
            items: dataManagementMenuItems(),
            selected: .export
        )
    }

    /// Runs the data management submenu until the operator leaves it.
    @discardableResult
    static func runDataManagementMenu() async throws -> DataManagementOutcome {
        while true {
            guard let action = try promptDataManagementAction() else {
                return .back
            }
            switch action {
            case .export:
                try runDataExport()
            case .importBackup:
                if try runDataImport() {
                    await MemoryGraphStoreRegistry.shared.reset()
                    return .dataReplaced
                }
            case .reset:
                guard try confirmRemoteConfigurationReset() else {
                    continue
                }
                try resetRemoteConfiguration()
                await MemoryGraphStoreRegistry.shared.reset()
                return .reset
            case .back:
                return .back
            }
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
