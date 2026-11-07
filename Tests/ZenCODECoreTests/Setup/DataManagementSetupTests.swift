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
}
