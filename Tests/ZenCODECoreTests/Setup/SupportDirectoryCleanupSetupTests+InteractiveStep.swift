//
//  SupportDirectoryCleanupSetupTests+InteractiveStep.swift
//  ZenCODECoreTests
//
//  Support directory cleanup tests for the interactive step shared with
//  Export backup: how it ends, cancelling from the group menu, and deleting
//  the selected groups.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import ZenCODECore
import Testing

extension SupportDirectoryCleanupSetupTests {
    // MARK: - Interactive step

    private struct Boom: Error {}

    private static func isCancelled(_ error: ZenCODESetupError?) -> Bool {
        if case .cancelled? = error {
            return true
        }
        return false
    }

    /// The paths of the full fixture, regenerable and protected, that are gone.
    private static func missingPopulatedPaths(_ fixture: Fixture) -> [String] {
        let paths = fixture.expectedPaths().values.flatMap { $0 } + Fixture.protectedPaths.map(fixture.path)
        return paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    private static func measuringLine(_ fixture: Fixture) -> String {
        "Measuring the regenerable data under \(fixture.supportURL.path)…\n"
    }

    @Test
    func cleanupStepReportsHowItEnded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        func step(
            select: Set<Group>?,
            confirm: () throws -> Bool
        ) throws -> Runner.SupportCleanupStepOutcome {
            try Runner.runSupportDirectoryCleanupStep(
                supportDirectoryURL: fixture.supportURL,
                write: { _ in },
                selectGroups: { _ in select },
                confirmDeletion: confirm
            )
        }

        #expect(try step(select: nil, confirm: { true }) == .menuCancelled)
        #expect(try step(select: [], confirm: { true }) == .noGroupSelected)
        #expect(try step(select: [.zencronBuild], confirm: { false }) == .declined)
        #expect(try step(select: [.zencronBuild], confirm: { throw ZenCODESetupError.cancelled }) == .confirmationCancelled)
        // Another error of the confirmation propagates.
        #expect(throws: Boom.self) {
            _ = try step(select: [.zencronBuild], confirm: { throw Boom() })
        }
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)

        let applied = try step(select: [.zencronBuild], confirm: { true })

        guard case let .applied(result) = applied else {
            Issue.record("Expected applied, got \(applied)")
            return
        }
        #expect(result.deleted.map(\.url.path) == [fixture.path("zencron/package/.build")])
        #expect(result.failures.isEmpty)
        #expect(!fixture.exists("zencron/package/.build"))
        #expect(fixture.exists("zencron/package/Package.swift"))

        let empty = try Fixture()
        defer { empty.remove() }
        try empty.file("settings.json")
        let nothing = try Runner.runSupportDirectoryCleanupStep(
            supportDirectoryURL: empty.supportURL,
            write: { _ in },
            selectGroups: { _ in nil },
            confirmDeletion: { true }
        )
        #expect(nothing == .nothingToClean)
    }

    @Test
    func exportStepEscOnTheGroupMenuCancelsTheExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var offered: [Group] = []
        var confirmations = 0

        let error = #expect(throws: ZenCODESetupError.self) {
            try Runner.runDataExportCleanupStep(
                supportDirectoryURL: fixture.supportURL,
                write: { output += $0 },
                selectGroups: { items in
                    offered = items.map(\.value)
                    return nil
                },
                confirmDeletion: {
                    confirmations += 1
                    return true
                }
            )
        }

        #expect(Self.isCancelled(error))
        #expect(offered == fixture.inventory().map(\.group))
        #expect(confirmations == 0)
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)
        #expect(output == Self.measuringLine(fixture))
    }

    @Test
    func exportStepYesDeletesTheSelectedGroupsAndContinues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var confirmations = 0

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { Set($0.map(\.value)).subtracting([.browserModel]) },
            confirmDeletion: {
                confirmations += 1
                return true
            }
        )

        #expect(confirmations == 1)
        let expected = fixture.expectedPaths()
        for path in expected[.browserModel]! {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
        for (group, paths) in expected where group != .browserModel {
            for path in paths {
                #expect(!FileManager.default.fileExists(atPath: path), "\(path)")
            }
        }
        for protected in Fixture.protectedPaths {
            #expect(fixture.exists(protected), "\(protected)")
        }
        #expect(fixture.inventory().map(\.group) == [.browserModel])
        #expect(output.contains("Freed "))
        #expect(!output.contains("Not deleted:"))
        #expect(!output.contains("Cleanup skipped"))
        #expect(!output.contains("Cleanup cancelled"))
    }
}
