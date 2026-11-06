//
//  DataManagementSetupTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 2026-08-24.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct DataManagementSetupTests {
    @Test
    func dataManagementSectionIsAvailableWithoutConfiguredModels() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        let dataOption = options.first { $0.section == .dataManagement }
        #expect(dataOption != nil)
        #expect(!SetupSection.dataManagement.requiresConfiguredModels)
        #expect(SetupSection.dataManagement.category == .optional)
        #expect(SetupSection.dataManagement.title == "Data management")
        #expect(dataOption?.detail == "export, import, clean memory, and reset ZenCODE data")
    }

    @Test
    func resetIsNotDuplicatedInTheMainMenu() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        let resetCount = options.filter { $0.section.title == "Reset remote configuration" }
            .count
        #expect(resetCount == 0, "Reset must live only in the data management submenu")
        #expect(ZenCODESetupRunner.dataManagementMenuItems().filter { $0.value == .reset }.count == 1)
    }

    @Test
    func dataManagementActionMatchesAliases() {
        #expect(SetupSection.dataManagement.matches("data"))
        #expect(SetupSection.dataManagement.matches("backup"))
        #expect(SetupSection.dataManagement.matches("export"))
        #expect(SetupSection.dataManagement.matches("import"))
        #expect(SetupSection.dataManagement.matches("data management"))
        #expect(!SetupSection.dataManagement.matches("telegram"))
    }

    @Test
    func dataManagementMenuItemsContainExportImportCleanupRebuildResetAndBack() throws {
        let items = ZenCODESetupRunner.dataManagementMenuItems()
        let titles = items.map(\.title)

        #expect(titles.contains("Export backup"))
        #expect(titles.contains("Import backup"))
        #expect(titles.contains("Clean memory"))
        #expect(titles.contains("Clean support directory"))
        #expect(titles.contains("Rebuild memory embeddings"))
        #expect(titles.contains("Reset remote configuration"))
        #expect(titles.contains("Back"))
        #expect(titles.last == "Back")
        #expect(titles.count == 7)
        // Clean memory, Clean support directory and Rebuild memory embeddings
        // sit between Import backup and Reset.
        let importIndex = try #require(titles.firstIndex(of: "Import backup"))
        #expect(titles[importIndex + 1] == "Clean memory")
        #expect(titles[importIndex + 2] == "Clean support directory")
        #expect(titles[importIndex + 3] == "Rebuild memory embeddings")
        #expect(titles[importIndex + 4] == "Reset remote configuration")
        #expect(items.map(\.value) == [
            .export, .importBackup, .cleanMemory, .cleanSupportDirectory, .rebuildEmbeddings, .reset, .back
        ])
        #expect(items[importIndex + 2].detail
            == "free disk space: delete browser caches and build files that are regenerated")
        #expect(items[importIndex + 3].detail
            == "embed entries missing a vector from the configured model, in every memory graph")
    }

    @Test
    func setupOutcomeDataReplacedIsDistinct() {
        #expect(SetupOutcome.dataReplaced != SetupOutcome.reset)
        #expect(SetupOutcome.dataReplaced != SetupOutcome.configured)
        #expect(SetupOutcome.dataReplaced != SetupOutcome.cancelled)
    }

    @Test
    func mainMenuGroupsDataManagementWithOptionalSections() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)
        let dataOptionIndex = options.firstIndex { $0.section == .dataManagement }
        #expect(dataOptionIndex != nil)

        // Options are grouped by category in display order; Data management
        // must sit between the other optional sections and Finish.
        let finishIndex = options.firstIndex { $0.section == .finish }
        #expect(dataOptionIndex! < finishIndex!)
        let firstOptionalIndex = options.firstIndex {
            $0.section.category == .optional
        }
        #expect(dataOptionIndex! >= firstOptionalIndex!)
    }

    @Test
    func exportAndImportRoundTripThroughRunnerHelpers() throws {
        // Verify the pure archive seam the interactive flow delegates to,
        // scoped to an isolated support directory override.
        let fileManager = FileManager.default
        let supportURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ZenCODE-datamgmt-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: supportURL) }
        try Data("{\"models\":[]}".utf8).write(
            to: supportURL.appendingPathComponent("settings.json")
        )
        try Data("secret".utf8).write(
            to: supportURL.appendingPathComponent(".env")
        )

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("datamgmt-\(UUID().uuidString).tar.gz")
        defer { try? fileManager.removeItem(at: archiveURL) }

        try AppStorageDirectory.withSupportDirectoryURL(supportURL) {
            let exported = try SupportDirectoryArchive.export(
                from: AppStorageDirectory.appSupportDirectoryURL(),
                to: archiveURL
            )
            #expect(exported.fileCount == 2)

            let imported = try SupportDirectoryArchive.import(
                from: archiveURL,
                into: AppStorageDirectory.appSupportDirectoryURL()
            )
            #expect(imported.fileCount == 2)
            #expect(
                try Data(
                    contentsOf: supportURL.appendingPathComponent("settings.json")
                ) == Data("{\"models\":[]}".utf8)
            )
        }
    }

    // MARK: - Export summary

    @Test
    func exportSummaryWithoutSkippedSymbolicLinksIsUnchanged() {
        let result = SupportDirectoryArchive.ExportResult(
            archiveURL: URL(fileURLWithPath: "/tmp/backup.tar.gz"),
            fileCount: 12,
            totalBytes: 3456,
            skippedSymbolicLinks: []
        )

        #expect(
            ZenCODESetupRunner.renderDataExportResult(result) == """

            Backup exported:
              File: /tmp/backup.tar.gz
              Files: 12
              Size (uncompressed): 3456 bytes

            Keep the archive private: it contains API keys and tokens.

            """
        )
    }

    @Test
    func exportSummaryListsSkippedSymbolicLinksWithTheirTargets() {
        let result = SupportDirectoryArchive.ExportResult(
            archiveURL: URL(fileURLWithPath: "/tmp/backup.tar.gz"),
            fileCount: 12,
            totalBytes: 3456,
            skippedSymbolicLinks: [
                .init(path: "features/demo/link", destination: "feature.json"),
                .init(path: "sneaky-link", destination: nil)
            ]
        )

        #expect(
            ZenCODESetupRunner.renderDataExportResult(result) == """

            Backup exported:
              File: /tmp/backup.tar.gz
              Files: 12
              Size (uncompressed): 3456 bytes
            Skipped symbolic links (2), not in the archive:
              - features/demo/link -> feature.json
              - sneaky-link

            Keep the archive private: it contains API keys and tokens.

            """
        )
    }

    // MARK: - Esc on the Data management menu, failed actions

    @Test
    func escOnTheDataManagementMenuGoesBackToTheMainMenu() async throws {
        // The terminal menu reports Esc as nil: the prompt passes it on
        // instead of throwing, so the `.back` branch is reached.
        var offered: [ZenCODESetupRunner.DataManagementAction] = []
        let action = ZenCODESetupRunner.promptDataManagementAction { title, items, selected in
            #expect(title == "Data management")
            #expect(selected == .export)
            offered = items.map(\.value)
            return nil
        }
        #expect(action == nil)
        #expect(offered.last == .back)

        var written: [String] = []
        let outcome = try await ZenCODESetupRunner.runDataManagementMenu(
            write: { written.append($0) },
            promptAction: { nil },
            importBackup: {
                Issue.record("Esc on the menu must not start an action")
                return false
            }
        )
        #expect(outcome == .back)
        #expect(written.isEmpty)
    }

    @Test
    func failedImportValidationStaysInDataManagement() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-datamgmt-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }
        let archiveURL = directoryURL.appendingPathComponent("not-a-backup.tar.gz")
        try Data("not an archive".utf8).write(to: archiveURL)

        var answers: [ZenCODESetupRunner.DataManagementAction?] = [.importBackup, nil]
        var prompts = 0
        var written: [String] = []
        let outcome = try await ZenCODESetupRunner.runDataManagementMenu(
            write: { written.append($0) },
            promptAction: {
                prompts += 1
                return answers.isEmpty ? nil : answers.removeFirst()
            },
            importBackup: {
                _ = try SupportDirectoryArchive.validate(archiveURL: archiveURL)
                Issue.record("A malformed archive must not validate")
                return true
            }
        )

        // The submenu opened again after the failure; its Esc then went back.
        #expect(prompts == 2)
        #expect(outcome == .back)
        #expect(written.count == 1)
        #expect(written.first?.hasPrefix("Import failed: ") == true)
    }

    @Test
    func dataManagementActionReportsEscAndFailuresAndRethrowsTaskCancellation() async throws {
        var written: [String] = []
        let cancelled: Int? = try await ZenCODESetupRunner.runningDataManagementAction(
            "Export",
            write: { written.append($0) }
        ) {
            throw ZenCODESetupError.cancelled
        }
        #expect(cancelled == nil)
        #expect(written == ["Export cancelled.\n\n"])

        written = []
        let failed: Int? = try await ZenCODESetupRunner.runningDataManagementAction(
            "Export",
            write: { written.append($0) }
        ) {
            throw ZenCODESetupError.noRemoteModelsReturned
        }
        #expect(failed == nil)
        #expect(written == [
            "Export failed: \(ZenCODESetupError.noRemoteModelsReturned.localizedDescription)\n\n"
        ])

        written = []
        let completed = try await ZenCODESetupRunner.runningDataManagementAction(
            "Export",
            write: { written.append($0) }
        ) {
            42
        }
        #expect(completed == 42)
        #expect(written.isEmpty)

        await #expect(throws: CancellationError.self) {
            _ = try await ZenCODESetupRunner.runningDataManagementAction(
                "Export",
                write: { _ in Issue.record("A task cancellation is not reported") }
            ) { () async throws -> Int in
                throw CancellationError()
            }
        }
    }

    @Test
    func dataManagementActionRethrowsEveryErrorOfACancelledTask() async {
        // Esc and failures alike, once the surrounding task has been
        // cancelled: Data management must not report them and open again.
        let errors: [any Error] = [ZenCODESetupError.cancelled, ZenCODESetupError.noRemoteModelsReturned]
        for error in errors {
            let outcome = await Task { () -> (rethrown: Bool, written: [String]) in
                withUnsafeCurrentTask { $0?.cancel() }
                var written: [String] = []
                do {
                    _ = try await ZenCODESetupRunner.runningDataManagementAction(
                        "Clean memory",
                        write: { written.append($0) }
                    ) { () async throws -> Int in
                        throw error
                    }
                    return (false, written)
                } catch {
                    return (true, written)
                }
            }.value
            #expect(outcome.rethrown, "\(error)")
            #expect(outcome.written.isEmpty, "\(error)")
        }
    }
}
