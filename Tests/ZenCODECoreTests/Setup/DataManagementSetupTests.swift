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

        let resetCount = options.filter { $0.section == .resetRemoteConfiguration }
            .count
        #expect(resetCount == 0, "Reset must live only in the data management submenu")
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

    // MARK: - Esc inside an action

    @Test
    func cancelledActionPromptReturnsToDataManagementWithItsMessage() throws {
        var written: [String] = []
        let value: Bool? = try ZenCODESetupRunner.returningToDataManagementOnCancel(
            "Import cancelled.",
            write: { written.append($0) }
        ) {
            throw ZenCODESetupError.cancelled
        }

        #expect(value == nil)
        #expect(written == ["Import cancelled.\n\n"])
    }

    @Test
    func completedActionReturnsItsValueWithoutAMessage() throws {
        var written: [String] = []
        let value = try ZenCODESetupRunner.returningToDataManagementOnCancel(
            "Reset cancelled.",
            write: { written.append($0) }
        ) {
            false
        }

        #expect(value == false)
        #expect(written.isEmpty)
    }

    @Test
    func otherActionErrorsStillPropagate() {
        var written: [String] = []
        let error = #expect(throws: ZenCODESetupError.self) {
            try ZenCODESetupRunner.returningToDataManagementOnCancel(
                "Export cancelled.",
                write: { written.append($0) }
            ) {
                throw ZenCODESetupError.invalidChoice("archive")
            }
        }
        if case .invalidChoice("archive")? = error {} else {
            Issue.record("Expected invalidChoice(\"archive\"), got \(String(describing: error))")
        }
        #expect(written.isEmpty)
    }
}
