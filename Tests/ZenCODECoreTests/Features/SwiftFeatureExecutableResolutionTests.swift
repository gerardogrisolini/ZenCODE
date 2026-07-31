//
//  SwiftFeatureExecutableResolutionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SwiftFeatureExecutableResolutionTests {
    @Test
    func swiftExecutableResolutionUsesProcessSearchPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-path-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let swiftURL = binURL.appendingPathComponent("swift")
        try Self.writeExecutable(at: swiftURL)

        let resolvedURL = try SwiftFeatureRuntime.swiftExecutableURL(
            fileManager: .default,
            environment: ["PATH": binURL.path],
            standardCandidatePaths: []
        )

        #expect(resolvedURL.path == swiftURL.standardizedFileURL.path)
    }

    @Test
    func swiftExecutableResolutionFindsDefaultSwiftlyInstallationWithoutSearchPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftly-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let swiftURL = homeURL
            .appendingPathComponent(".local/share/swiftly/bin", isDirectory: true)
            .appendingPathComponent("swift")
        try Self.writeExecutable(at: swiftURL)

        let resolvedURL = try SwiftFeatureRuntime.swiftExecutableURL(
            fileManager: .default,
            environment: ["HOME": homeURL.path, "PATH": "/missing"],
            standardCandidatePaths: []
        )

        #expect(resolvedURL.path == swiftURL.standardizedFileURL.path)
    }

    @Test
    func missingSwiftExecutableProducesActionableErrorInsteadOfReturningMissingUsrBinPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-swift-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            _ = try SwiftFeatureRuntime.swiftExecutableURL(
                fileManager: .default,
                environment: ["HOME": rootURL.path, "PATH": "/missing"],
                standardCandidatePaths: []
            )
            Issue.record("Expected Swift executable resolution to fail.")
        } catch {
            #expect(error.localizedDescription.contains("Swift executable not found"))
            #expect(error.localizedDescription.contains("SWIFT_EXECUTABLE"))
            #expect(error.localizedDescription.contains("Swiftly"))
        }
    }

    private static func writeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
