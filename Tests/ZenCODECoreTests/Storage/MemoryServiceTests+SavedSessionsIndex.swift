//
//  MemoryServiceTests+SavedSessionsIndex.swift
//  ZenCODE
//
//  Memory service tests for the saved sessions index: latest session per
//  project, removal, private filesystem entries, and concurrent writes, with
//  their POSIX and write-barrier helpers.
//

import Foundation
import ToolCore
@testable import ZenCODECore
import Testing

extension MemoryServiceTests {
    @Test
    func savedSessionsIndexKeepsLatestSessionPerProject() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let firstProjectURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = rootURL.appendingPathComponent("second", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "first checkpoint",
            sessionID: "first-session-old",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try store.recordSavedSession(
            projectPath: secondProjectURL.path,
            sessionName: "second checkpoint",
            sessionID: "second-session",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "first latest",
            sessionID: "first-session-new",
            savedAt: Date(timeIntervalSince1970: 300)
        )

        let sessions = store.sessions()

        #expect(store.sessionsFileURL().lastPathComponent == "sessions.json")
        #expect(FileManager.default.fileExists(atPath: store.sessionsFileURL().path))
        #expect(sessions.count == 2)
        #expect(sessions.first?.sessionID == "first-session-new")
        #expect(sessions.first?.sessionName == "first latest")
        #expect(sessions.contains { $0.sessionID == "second-session" })
        #expect(!sessions.contains { $0.sessionID == "first-session-old" })
    }

    @Test
    func savedSessionsIndexRemovesTheDeletedSessionOfItsProject() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let firstProjectURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = rootURL.appendingPathComponent("second", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "first checkpoint",
            sessionID: "first-session",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try store.recordSavedSession(
            projectPath: secondProjectURL.path,
            sessionName: "second checkpoint",
            sessionID: "second-session",
            savedAt: Date(timeIntervalSince1970: 200)
        )

        // The path and the name are normalized as when the entry was recorded.
        let removed = try store.removeSavedSession(
            projectPath: firstProjectURL.path + "/./",
            sessionName: "  first checkpoint \n"
        )

        #expect(removed)
        #expect(store.sessions().map(\.sessionID) == ["second-session"])
    }

    @Test
    func savedSessionsIndexRemovalKeepsOtherSessionsAndLeavesTheFileUntouched() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let firstProjectURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = rootURL.appendingPathComponent("second", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "latest",
            sessionID: "first-session",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let originalData = try Data(contentsOf: store.sessionsFileURL())

        // Another session of the same project, and the same name in another
        // project, are not the indexed entry.
        #expect(try store.removeSavedSession(projectPath: firstProjectURL.path, sessionName: "older") == false)
        #expect(try store.removeSavedSession(projectPath: secondProjectURL.path, sessionName: "latest") == false)

        #expect(try Data(contentsOf: store.sessionsFileURL()) == originalData)
        #expect(store.sessions().map(\.sessionID) == ["first-session"])
    }

    @Test
    func savedSessionsIndexRemovalWithoutAnIndexCreatesNoFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        let removed = try store.removeSavedSession(
            projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
            sessionName: "missing"
        )

        #expect(!removed)
        #expect(!FileManager.default.fileExists(atPath: store.sessionsFileURL().path))
    }

    @Test
    func savedSessionsIndexRemovalRequiresASessionName() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        #expect(throws: MemoryServiceError.self) {
            try store.removeSavedSession(
                projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
                sessionName: " \n "
            )
        }
    }

    @Test
    func savedSessionsIndexCreatesPrivateFilesystemEntries() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
            sessionName: "private checkpoint",
            sessionID: "private-session",
            savedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(try savedSessionsPOSIXMode(of: storeDirectoryURL, fileManager: fileManager) == 0o700)
        #expect(try savedSessionsPOSIXMode(of: store.sessionsFileURL(), fileManager: fileManager) == 0o600)
        let filenames = try fileManager.contentsOfDirectory(atPath: storeDirectoryURL.path)
        #expect(!filenames.contains { $0.hasSuffix(".tmp") })
        #else
        return
        #endif
    }

    @Test
    func savedSessionsIndexTightensPermissiveExistingEntriesWithoutChangingData() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
            sessionName: "legacy checkpoint",
            sessionID: "legacy-session",
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let fileURL = store.sessionsFileURL()
        let originalData = try Data(contentsOf: fileURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: storeDirectoryURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fileURL.path
        )

        let sessions = store.sessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.sessionID == "legacy-session")
        #expect(try Data(contentsOf: fileURL) == originalData)
        #expect(try savedSessionsPOSIXMode(of: storeDirectoryURL, fileManager: fileManager) == 0o700)
        #expect(try savedSessionsPOSIXMode(of: fileURL, fileManager: fileManager) == 0o600)
        #else
        return
        #endif
    }

    @Test
    func savedSessionsIndexRejectsDestinationSymlinkWithoutTouchingTarget() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let targetURL = rootURL.appendingPathComponent("unrelated.json")
        defer { try? fileManager.removeItem(at: rootURL) }

        try fileManager.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
        let targetData = Data("unrelated target".utf8)
        try targetData.write(to: targetURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: targetURL.path
        )
        try fileManager.createSymbolicLink(
            at: storeDirectoryURL.appendingPathComponent(SavedSessionsStore.filename),
            withDestinationURL: targetURL
        )

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        do {
            try store.recordSavedSession(
                projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
                sessionName: "should fail",
                sessionID: "symlink-session",
                savedAt: Date(timeIntervalSince1970: 3)
            )
            Issue.record("Saved sessions must reject a destination symlink.")
        } catch {
            // Expected: SensitiveFilePermissions fails closed for symlinks.
        }

        #expect(try Data(contentsOf: targetURL) == targetData)
        #expect(try savedSessionsPOSIXMode(of: targetURL, fileManager: fileManager) == 0o644)
        #else
        return
        #endif
    }

    @Test
    func savedSessionsIndexRetainsConcurrentWritesAcrossInstances() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let writeCount = 64
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let barrier = SavedSessionsWriteBarrier(participantCount: writeCount)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writeCount {
                group.addTask {
                    let directoryURL = index.isMultiple(of: 2)
                        ? storeDirectoryURL
                        : storeDirectoryURL.appendingPathComponent(".")
                    let store = SavedSessionsStore(directoryURL: directoryURL)
                    await barrier.wait()
                    try store.recordSavedSession(
                        projectPath: rootURL.appendingPathComponent("project-\(index)").path,
                        sessionName: "checkpoint \(index)",
                        sessionID: "session-\(index)",
                        savedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                }
            }
            try await group.waitForAll()
        }

        let sessions = SavedSessionsStore(directoryURL: storeDirectoryURL).sessions()
        #expect(sessions.count == writeCount)
        #expect(Set(sessions.map(\.sessionID)) == Set((0..<writeCount).map { "session-\($0)" }))
        #expect(Set(sessions.map(\.projectPath)).count == writeCount)
    }
}

#if canImport(Darwin) || canImport(Glibc)
private func savedSessionsPOSIXMode(of url: URL, fileManager: FileManager) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw SavedSessionsPOSIXTestError.missingPermissions(url)
    }
    return permissions.intValue & 0o777
}

private enum SavedSessionsPOSIXTestError: Error {
    case missingPermissions(URL)
}
#endif

private actor SavedSessionsWriteBarrier {
    private let participantCount: Int
    private var arrivedCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        arrivedCount += 1
        guard arrivedCount < participantCount else {
            let waitingTasks = waiters
            waiters.removeAll()
            for waiter in waitingTasks {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
