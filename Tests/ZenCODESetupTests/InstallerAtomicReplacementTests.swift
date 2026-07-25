//
//  InstallerAtomicReplacementTests.swift
//  ZenCODE
//

import Foundation
import Testing

@Suite
struct InstallerAtomicReplacementTests {
    @Test
    func executableReplacementPreservesTheInodeHeldByARunningProcess() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let destinationDirectory = temporaryDirectory
            .appendingPathComponent("destination with spaces", isDirectory: true)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let sourceURL = temporaryDirectory.appendingPathComponent("new-zen")
        let targetURL = destinationDirectory.appendingPathComponent("zen")
        try Data("new executable\n".utf8).write(to: sourceURL)
        try Data("old executable\n".utf8).write(to: targetURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: targetURL.path
        )

        let oldExecutableHandle = try FileHandle(forReadingFrom: targetURL)
        defer {
            try? oldExecutableHandle.close()
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = packageRoot
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("install-support.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -euo pipefail
            SUDO=""
            source "$1"
            zencode_install_executable_atomically "$2" "$3"
            """,
            "zencode-installer-test",
            helperURL.path,
            sourceURL.path,
            targetURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
        #expect(
            process.terminationStatus == 0,
            "Atomic installer helper failed: \(errorText)"
        )

        try oldExecutableHandle.seek(toOffset: 0)
        let contentHeldByRunningProcess = try oldExecutableHandle.readToEnd()
        let newlyInstalledContent = try Data(contentsOf: targetURL)

        #expect(contentHeldByRunningProcess == Data("old executable\n".utf8))
        #expect(newlyInstalledContent == Data("new executable\n".utf8))

        let permissions = try fileManager.attributesOfItem(atPath: targetURL.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o755)

        let stagedFiles = try fileManager.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".zen.install.") }
        #expect(stagedFiles.isEmpty)
    }
}
