//
//  ZenCronJobCommandTests+LocatingZen.swift
//  ZenCODE
//
//  Tests of the lookup of the zen executable on the PATH, with the temporary
//  directories and the probe they use.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension ZenCronJobCommandTests {
    // MARK: - locating zen

    private func withTemporaryDirectories(
        _ count: Int,
        _ body: ([URL]) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("zen-cron-locate-\(UUID().uuidString)", isDirectory: true)
        let directories = (0..<count).map { index in
            root.appendingPathComponent("dir\(index)-\(UUID().uuidString)", isDirectory: true)
        }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }
        try body(directories)
    }

    private func writeZen(in directory: URL, executable: Bool) throws -> String {
        let url = directory.appendingPathComponent("zen")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url.path
    }

    @Test
    func locateZenReturnsTheFirstExecutableZenOnThePath() throws {
        try withTemporaryDirectories(2) { directories in
            let first = try writeZen(in: directories[0], executable: true)
            _ = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == first)

            let reversed = directories.reversed().map(\.path).joined(separator: ":")
            #expect(
                ZenCronJobCommand.locateZen(onPath: reversed)
                    == directories[1].appendingPathComponent("zen").path
            )
        }
    }

    @Test
    func locateZenSkipsANonExecutableZenAndFallsThroughToTheNextDirectory() throws {
        try withTemporaryDirectories(2) { directories in
            _ = try writeZen(in: directories[0], executable: false)
            let second = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == second)
        }
    }

    @Test
    func locateZenIgnoresEmptyAndRelativeEntries() {
        let probe = ExecutableProbe(executables: ["/fixture/zen"])
        let path = ":.::./:bin:~/bin:$HOME/bin::/fixture::/other:"
        #expect(ZenCronJobCommand.locateZen(onPath: path, isExecutableFile: probe.isExecutableFile) == "/fixture/zen")
        // Only the absolute entries up to the match were probed.
        #expect(probe.probedPaths == ["/fixture/zen"])

        let miss = ExecutableProbe(executables: [])
        #expect(ZenCronJobCommand.locateZen(onPath: path, isExecutableFile: miss.isExecutableFile) == nil)
        #expect(miss.probedPaths == ["/fixture/zen", "/other/zen"])
    }
}

/// Records every path asked about and reports a fixed set as executable, so
/// `locateZen` is tested without touching the machine's PATH.
private final class ExecutableProbe: Sendable {
    private let executables: Set<String>
    private let probed = Mutex<[String]>([])

    init(executables: Set<String>) {
        self.executables = executables
    }

    var probedPaths: [String] {
        probed.withLock { $0 }
    }

    func isExecutableFile(_ path: String) -> Bool {
        probed.withLock { $0.append(path) }
        return executables.contains(path)
    }
}
