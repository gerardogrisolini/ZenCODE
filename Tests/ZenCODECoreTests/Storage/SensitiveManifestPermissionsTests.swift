//
//  SensitiveManifestPermissionsTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 18/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct SensitiveManifestPermissionsTests {
    @Test
    func savingSensitiveManifestsCreatesPrivateDirectoryAndFiles() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let directoryURL = try makeTemporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let settingsURL = directoryURL.appendingPathComponent("settings.json")
        let permissionsURL = directoryURL.appendingPathComponent("permissions.json")

        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: []),
            to: settingsURL
        )
        try AgentPermissionsManifestStore.save(
            AgentPermissionsManifest(localExecAllowedCommands: ["swift"]),
            to: permissionsURL
        )

        #expect(try posixMode(of: directoryURL, fileManager: fileManager) == 0o700)
        #expect(try posixMode(of: settingsURL, fileManager: fileManager) == 0o600)
        #expect(try posixMode(of: permissionsURL, fileManager: fileManager) == 0o600)
        let filenames = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        #expect(!filenames.contains { $0.hasSuffix(".tmp") })
        #else
        // ACL semantics are platform-specific; POSIX mode assertions apply to
        // the supported macOS, Linux, and WSL runtime paths.
        return
        #endif
    }

    @Test
    func loadingLegacySensitiveManifestsMigratesPermissionsWithoutChangingData() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let directoryURL = try makeTemporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let settingsURL = directoryURL.appendingPathComponent("settings.json")
        let permissionsURL = directoryURL.appendingPathComponent("permissions.json")
        let settings = AgentSettingsManifest(models: [])
        let permissions = AgentPermissionsManifest(localExecAllowedCommands: ["swift"])

        try AgentSettingsManifestStore.save(settings, to: settingsURL)
        try AgentPermissionsManifestStore.save(permissions, to: permissionsURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: directoryURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: settingsURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: permissionsURL.path
        )

        let loadedSettings = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
        let loadedPermissions = try AgentPermissionsManifestStore.loadRequired(from: permissionsURL)

        #expect(loadedSettings == settings)
        #expect(loadedPermissions == permissions)
        #expect(try posixMode(of: directoryURL, fileManager: fileManager) == 0o700)
        #expect(try posixMode(of: settingsURL, fileManager: fileManager) == 0o600)
        #expect(try posixMode(of: permissionsURL, fileManager: fileManager) == 0o600)
        #else
        // ACL semantics are platform-specific; POSIX mode assertions apply to
        // the supported macOS, Linux, and WSL runtime paths.
        return
        #endif
    }

    @Test
    func sensitiveManifestsRejectSymbolicLinksWithoutTouchingTheirTargets() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let directoryURL = try makeTemporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let targetURL = directoryURL.appendingPathComponent("unrelated.json")
        let targetData = try JSONEncoder().encode(AgentSettingsManifest(models: []))
        try targetData.write(to: targetURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: targetURL.path
        )

        let linkedSettingsURL = directoryURL.appendingPathComponent("settings.json")
        try fileManager.createSymbolicLink(
            at: linkedSettingsURL,
            withDestinationURL: targetURL
        )

        do {
            _ = try AgentSettingsManifestStore.loadRequired(from: linkedSettingsURL)
            Issue.record("Loading a sensitive manifest through a symlink must fail closed.")
        } catch {
            // Expected: the hardening boundary rejects a non-regular file.
        }
        do {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: []),
                to: linkedSettingsURL
            )
            Issue.record("Saving a sensitive manifest through a symlink must fail closed.")
        } catch {
            // Expected: the existing destination is not a regular file.
        }

        let targetAfterReadAndWrite = try Data(contentsOf: targetURL)
        let targetModeAfterReadAndWrite = try posixMode(of: targetURL, fileManager: fileManager)
        #expect(targetAfterReadAndWrite == targetData)
        #expect(targetModeAfterReadAndWrite == 0o644)
        #expect(fileManager.fileExists(atPath: linkedSettingsURL.path))

        let targetDirectoryURL = directoryURL.appendingPathComponent("unrelated-directory")
        try fileManager.createDirectory(at: targetDirectoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: targetDirectoryURL.path
        )
        let linkedDirectoryURL = directoryURL.appendingPathComponent("linked-directory")
        try fileManager.createSymbolicLink(
            at: linkedDirectoryURL,
            withDestinationURL: targetDirectoryURL
        )

        do {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: []),
                to: linkedDirectoryURL.appendingPathComponent("settings.json")
            )
            Issue.record("Saving below a sensitive directory symlink must fail closed.")
        } catch {
            // Expected: the parent path is a symbolic link, not a directory.
        }

        let targetDirectoryModeAfterWrite = try posixMode(
            of: targetDirectoryURL,
            fileManager: fileManager
        )
        #expect(targetDirectoryModeAfterWrite == 0o755)
        #expect(!fileManager.fileExists(
            atPath: targetDirectoryURL.appendingPathComponent("settings.json").path
        ))
        #else
        return
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func makeTemporaryDirectory(fileManager: FileManager) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-sensitive-manifests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func posixMode(of url: URL, fileManager: FileManager) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw SensitiveManifestPermissionsTestError.missingPOSIXPermissions(url)
        }
        return permissions.intValue & 0o777
    }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
private enum SensitiveManifestPermissionsTestError: Error {
    case missingPOSIXPermissions(URL)
}
#endif
