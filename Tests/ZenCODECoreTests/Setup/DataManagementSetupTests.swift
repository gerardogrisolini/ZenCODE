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
        #expect(dataOption?.detail == "export, import, and reset ZenCODE data")
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
    func dataManagementMenuItemsContainExportImportResetAndBack() throws {
        let items = ZenCODESetupRunner.dataManagementMenuItems()
        let titles = items.map(\.title)

        #expect(titles.contains("Export backup"))
        #expect(titles.contains("Import backup"))
        #expect(titles.contains("Reset remote configuration"))
        #expect(titles.contains("Back"))
        #expect(titles.last == "Back")
        #expect(titles.count == 4)
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
}
