import Foundation
import ToolCore

/// ACP owns the RPCs; the neutral runtime sees only transient text operations.
/// A client read is not an atomic snapshot of a later client write. We serialize
/// our own edits, recheck the preimage and verify the acknowledged result, but
/// cannot lock out external editor changes between requests.
final class ACPClientFileSystem: Sendable {
    let canRead: Bool
    let canWrite: Bool
    private let writer: ACPWriter
    private let timeout: Duration
    // Reuse the cancellation-aware keyed FIFO, with absolute paths as lease keys.
    private let fileLeases = AgentSessionTurnLease()

    init(writer: ACPWriter, canRead: Bool, canWrite: Bool, timeout: Duration = .seconds(30)) {
        self.writer = writer
        self.canRead = canRead
        self.canWrite = canWrite
        self.timeout = timeout
    }

    static func negotiated(writer: ACPWriter, params: [String: Any]) -> ACPClientFileSystem? {
        // JSONValue preserves the boolean wire type (NSNumber/`as? Bool` does not).
        guard let data = try? JSONSerialization.data(withJSONObject: params),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        let fs = value.objectValue?["clientCapabilities"]?.objectValue?["fs"]?.objectValue
        let read = fs?["readTextFile"] == .bool(true)
        let write = fs?["writeTextFile"] == .bool(true)
        guard read || write else { return nil }
        return .init(writer: writer, canRead: read, canWrite: write)
    }

    func access(
        sessionID: String,
        isValid: @escaping @Sendable () async -> Bool
    ) -> ClientTextFileSystem {
        let read: ClientTextFileSystem.Read = { path in
            try await self.read(path, sessionID: sessionID, isValid: isValid)
        }
        let write: ClientTextFileSystem.Write = { path, contents in
            try await self.fileLeases.withLease(sessionID: path.standardizedFileURL.path) {
                var before: String?
                if self.canRead {
                    do {
                        before = try await self.read(path, sessionID: sessionID, isValid: isValid)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as ACPFileSystemTimeout {
                        throw error
                    } catch {
                        // ACP does not standardize a missing-file error code.
                        // A failed read is unknown, never evidence of absence.
                    }
                }
                try await self.commit(
                    contents, before: before, path: path,
                    sessionID: sessionID, isValid: isValid)
            }
        }
        let edit: ClientTextFileSystem.Edit = { path, transform in
            try await self.fileLeases.withLease(sessionID: path.standardizedFileURL.path) {
                let before = try await self.read(path, sessionID: sessionID, isValid: isValid)
                let after = try transform(before)
                try await self.commit(
                    after, before: before, path: path,
                    sessionID: sessionID, isValid: isValid)
                return (before, after)
            }
        }
        return ClientTextFileSystem(
            read: canRead ? read : nil,
            write: canWrite ? write : nil,
            edit: canRead && canWrite ? edit : nil
        )
    }

    private func read(
        _ path: URL, sessionID: String,
        isValid: @escaping @Sendable () async -> Bool
    ) async throws -> String {
        let result = try await request(
            "fs/read_text_file", path: path, sessionID: sessionID,
            isValid: isValid)
        guard case .string(let contents)? = result?.objectValue?["content"] else {
            throw ACPError.internalError("ACP client returned invalid text file content.")
        }
        return contents
    }

    private func commit(
        _ contents: String, before: String?, path: URL, sessionID: String,
        isValid: @escaping @Sendable () async -> Bool
    ) async throws {
        if let before {
            let current = try await read(path, sessionID: sessionID, isValid: isValid)
            guard current.utf8.elementsEqual(before.utf8) else {
                throw ACPError.internalError(
                    "The client file changed before the write. Re-read it and retry; nothing was written.")
            }
        }
        let result = try await request(
            "fs/write_text_file", path: path, contents: contents,
            sessionID: sessionID, isValid: isValid)
        guard result == .null || result == .object([:]) else {
            throw ACPError.internalError(
                "ACP client returned an invalid write acknowledgment; the file may have changed.")
        }
        // Once acknowledged, a failed verification must not misreport the write
        // as failed and invite a blind retry. Only the presentation degrades.
        var verified = false
        if canRead {
            do {
                let after = try await read(path, sessionID: sessionID, isValid: isValid)
                verified = after.utf8.elementsEqual(contents.utf8)
            } catch {
                verified = false
            }
        }
        guard let recorder = OperationFileChangeRecorder.current else { return }
        guard let before, verified,
            !before.contains("\0"), !contents.contains("\0")
        else {
            recorder.record(
                .init(
                    path: path.path, oldText: nil, newText: nil,
                    explanation:
                        "Client write acknowledged. Diff unavailable: previous content is unknown, verification failed, or concurrent changes make the comparison uncertain."
                ))
            return
        }
        guard !before.utf8.elementsEqual(contents.utf8) else { return }
        recorder.record(.init(path: path.path, oldText: before, newText: contents))
    }

    private func request(
        _ method: String, path: URL, contents: String? = nil, sessionID: String,
        isValid: @escaping @Sendable () async -> Bool
    ) async throws -> JSONValue? {
        try Task.checkCancellation()
        guard await isValid() else { throw CancellationError() }
        let path = path.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ACPError.invalidParams("Client file path must be absolute and contain no NUL.")
        }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "path": .string(path)]
        if let contents { params["content"] = .string(contents) }
        let payload = JSONValue.object(params)
        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask(name: "ACP client filesystem request") {
                try Task.checkCancellation()
                guard await isValid() else { throw CancellationError() }
                return try await self.writer.request(method: method, params: payload)
            }
            group.addTask(name: "ACP client filesystem timeout") {
                try await Task.sleep(for: self.timeout)
                throw ACPFileSystemTimeout()
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            try Task.checkCancellation()
            guard await isValid() else { throw CancellationError() }
            return result
        }
    }
}

private struct ACPFileSystemTimeout: LocalizedError {
    var errorDescription: String? {
        "ACP client filesystem request timed out. An already sent write may have completed; inspect the file before retrying."
    }
}

extension ZenCODEACPBridge {
    func canUseClientFileSystem(sessionID: String, epoch: UInt64) -> Bool {
        liveSession(id: sessionID, epoch: epoch) != nil
    }
}
