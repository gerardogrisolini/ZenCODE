import FeatureKit
import Foundation
import LocalToolsSupport
import Synchronization
import Testing
import ToolCore

@testable import ZenCODECore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ACPClientFileSystemTests {
    @Test func negotiationRequiresBooleanFlagsAndSupportsPartialCapabilities() throws {
        let writer = ACPWriter { _ in }
        for raw in ["{}", #"{"clientCapabilities":{"fs":{"readTextFile":1,"writeTextFile":"true"}}}"#] {
            let params = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            #expect(ACPClientFileSystem.negotiated(writer: writer, params: params) == nil)
        }
        for (read, write) in [(true, false), (false, true), (true, true)] {
            let client = try #require(
                ACPClientFileSystem.negotiated(
                    writer: writer,
                    params: [
                        "clientCapabilities": ["fs": ["readTextFile": read, "writeTextFile": write]]
                    ]))
            let access = client.access(sessionID: "root") { true }
            #expect((access.read != nil) == read)
            #expect((access.write != nil) == write)
            #expect((access.edit != nil) == (read && write))
        }
    }

    @Test func localToolsUseUnsavedClientBuffersAndRecordStandardDiff() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("File.swift")
        try "DISK\n".write(to: file, atomically: true, encoding: .utf8)
        let fixture = FileSystemClientFixture(files: [file.path: "before\n"])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let recorder = OperationFileChangeRecorder()
        let access = harness.client.access(sessionID: "root-session") { true }
        try await ClientTextFileSystem.$current.withValue(access) {
            let read = try await invoke("local.readFile", ["path": "File.swift"], root: root)
            #expect(read.contains("before"))
            #expect(!read.contains("DISK"))
            try await OperationFileChangeRecorder.$current.withValue(recorder) {
                _ = try await invoke(
                    "local.editFile", ["path": "File.swift", "old": "before", "new": "after"], root: root)
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "DISK\n")
        #expect(await fixture.text(at: file.path) == "after\n")
        #expect(recorder.changes == [.init(path: file.path, oldText: "before\n", newText: "after\n")])
        let requests = await fixture.requests
        #expect(requests.allSatisfy { $0.objectValue?["params"]?.objectValue?["sessionId"] == .string("root-session") })
        let call = DirectAgentToolCall(id: "edit", name: "local.editFile", argumentsObject: [:], argumentsJSON: "{}")
        let update = ZenCODEACPBridge.toolCallCompletionJSONUpdate(
            for: call,
            result: .init(
                output: "updated", summary: "updated", status: .completed, fileChanges: recorder.changes))
        #expect(
            update.objectValue?["content"]?.arrayValue?.contains { $0.objectValue?["type"] == .string("diff") } == true)
    }

    @Test func readFilesReplaceMultiEditAndWriteKeepTheirExistingContracts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("File.swift")
        let fixture = FileSystemClientFixture(files: [file.path: "one one\ntwo\n"])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        try await ClientTextFileSystem.$current.withValue(harness.client.access(sessionID: "root") { true }) {
            let lines = try await invoke(
                "local.readFiles", ["paths": ["File.swift"], "offset": 2, "limit": 1], root: root)
            #expect(lines.contains("2\ttwo"))
            _ = try await invoke("local.replace", ["path": "File.swift", "old": "one", "new": "three"], root: root)
            #expect(await fixture.text(at: file.path) == "three three\ntwo\n")
            let writesBeforeFailure = await fixture.writeCount
            await #expect(throws: (any Error).self) {
                _ = try await invoke(
                    "local.multiEdit",
                    [
                        "path": "File.swift",
                        "edits": [
                            ["old": "two", "new": "four"], ["old": "missing", "new": "five"],
                        ],
                    ], root: root)
            }
            #expect(await fixture.writeCount == writesBeforeFailure)
            _ = try await invoke(
                "local.multiEdit",
                [
                    "path": "File.swift",
                    "edits": [
                        ["old": "two", "new": "four"], ["old": "three three", "new": "five"],
                    ],
                ], root: root)
            #expect(await fixture.text(at: file.path) == "five\nfour\n")
            _ = try await invoke("local.writeFile", ["path": "File.swift", "content": "final\n"], root: root)
            #expect(await fixture.text(at: file.path) == "final\n")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deniedOrMalformedReadsNeverFallBackToDiskOrWrite() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("File.swift")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        for behavior in [FileSystemClientFixture.Behavior.deny, .malformedRead] {
            let fixture = FileSystemClientFixture(files: [file.path: "before"], behavior: behavior)
            let harness = FileSystemHarness(fixture: fixture)
            defer { harness.stop() }
            await ClientTextFileSystem.$current.withValue(harness.client.access(sessionID: "root") { true }) {
                await #expect(throws: (any Error).self) {
                    _ = try await invoke(
                        "local.editFile", ["path": "File.swift", "old": "before", "new": "after"], root: root)
                }
            }
            #expect(await fixture.writeCount == 0)
            #expect(try String(contentsOf: file, encoding: .utf8) == "before")
        }
    }

    @Test func deniedWritesDoNotTouchDiskOrPublishDiffs() async throws {
        let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": "before"], behavior: .denyWrite)
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let recorder = OperationFileChangeRecorder()
        let write = try #require(harness.client.access(sessionID: "root") { true }.write)
        await #expect(throws: (any Error).self) {
            try await OperationFileChangeRecorder.$current.withValue(recorder) {
                try await write(URL(fileURLWithPath: "/tmp/file.swift"), "after")
            }
        }
        #expect(await fixture.text(at: "/tmp/file.swift") == "before")
        #expect(recorder.changes.isEmpty)
    }

    @Test func byteIdenticalNoOpsAreSkippedButUnicodeByteChangesRemainDiffs() async throws {
        for after in ["e\u{301}", "é"] {
            let before = "e\u{301}"
            let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": before])
            let harness = FileSystemHarness(fixture: fixture)
            defer { harness.stop() }
            let recorder = OperationFileChangeRecorder()
            let write = try #require(harness.client.access(sessionID: "root") { true }.write)
            try await OperationFileChangeRecorder.$current.withValue(recorder) {
                try await write(URL(fileURLWithPath: "/tmp/file.swift"), after)
            }
            #expect(recorder.changes.count == (before.utf8.elementsEqual(after.utf8) ? 0 : 1))
        }
    }

    @Test func descriptorGuidanceIsTransientAndDoesNotChangeToolIdentity() async {
        let descriptor = DirectToolDescriptor(name: "local.editFile", description: "Edit", inputSchema: "{}")
        #expect(DirectToolExecutor.clientTextFileDescriptor(descriptor).description == "Edit")
        let client = ClientTextFileSystem(
            read: { _ in "" }, write: { _, _ in }, edit: { _, transform in ("", try transform("")) })
        ClientTextFileSystem.$current.withValue(client) {
            let adapted = DirectToolExecutor.clientTextFileDescriptor(descriptor)
            #expect(adapted.name == descriptor.name)
            #expect(adapted.inputSchema == descriptor.inputSchema)
            #expect(adapted.description.contains("CLIENT EDITOR FILESYSTEM"))
        }
        #expect(DirectToolExecutor.clientTextFileDescriptor(descriptor).description == "Edit")
    }

    @Test func concurrentClientChangeAbortsBeforeWrite() async throws {
        let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": "before"], behavior: .changeBeforeWrite)
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let edit = try #require(harness.client.access(sessionID: "root") { true }.edit)
        await #expect(throws: (any Error).self) {
            _ = try await edit(URL(fileURLWithPath: "/tmp/file.swift")) { _ in "after" }
        }
        #expect(await fixture.writeCount == 0)
    }

    @Test func verificationFailureDoesNotTurnAcknowledgedWriteIntoRetryableFailure() async throws {
        let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": "before"], behavior: .changeAfterWrite)
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let recorder = OperationFileChangeRecorder()
        let edit = try #require(harness.client.access(sessionID: "root") { true }.edit)
        _ = try await OperationFileChangeRecorder.$current.withValue(recorder) {
            try await edit(URL(fileURLWithPath: "/tmp/file.swift")) { _ in "after" }
        }
        #expect(await fixture.writeCount == 1)
        #expect(recorder.changes.count == 1)
        #expect(recorder.changes.first?.explanation != nil)
        #expect(recorder.changes.first?.oldText == nil)
    }

    @Test func missingPreimageAndOversizeEvidenceFallBackWithoutTruncation() async throws {
        for old in [String?.none, String(repeating: "a", count: OperationFileChangeRecorder.maximumTextBytes + 1)] {
            let fixture = FileSystemClientFixture(files: old.map { ["/tmp/file.swift": $0] } ?? [:])
            let harness = FileSystemHarness(fixture: fixture)
            defer { harness.stop() }
            let write = try #require(harness.client.access(sessionID: "root") { true }.write)
            let recorder = OperationFileChangeRecorder()
            try await OperationFileChangeRecorder.$current.withValue(recorder) {
                try await write(URL(fileURLWithPath: "/tmp/file.swift"), "after")
            }
            #expect(await fixture.text(at: "/tmp/file.swift") == "after")
            #expect(recorder.changes.count == 1)
            #expect(recorder.changes.first?.explanation != nil)
            #expect(recorder.changes.first?.oldText == nil)
        }
    }

    @Test func cancelledOrStaleSessionCannotSendWrites() async throws {
        let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": "before"])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let edit = try #require(harness.client.access(sessionID: "stale") { false }.edit)
        await #expect(throws: CancellationError.self) {
            _ = try await edit(URL(fileURLWithPath: "/tmp/file.swift")) { _ in "after" }
        }
        #expect(await fixture.requests.isEmpty)
        let access = harness.client.access(sessionID: "root") { true }
        let cancelled = Task(name: "Cancelled client write test") {
            withUnsafeCurrentTask { $0?.cancel() }
            try await access.write?(URL(fileURLWithPath: "/tmp/file.swift"), "after")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await fixture.requests.isEmpty)
    }

    @Test func timeoutAndTransportCloseReleasePendingRequests() async throws {
        let fixture = FileSystemClientFixture(files: [:], behavior: .stall)
        let harness = FileSystemHarness(fixture: fixture, timeout: .milliseconds(30))
        defer { harness.stop() }
        let read = try #require(harness.client.access(sessionID: "root") { true }.read)
        await #expect(throws: (any Error).self) { _ = try await read(URL(fileURLWithPath: "/tmp/file.swift")) }
        await harness.writer.close()
        await #expect(throws: (any Error).self) { _ = try await read(URL(fileURLWithPath: "/tmp/file.swift")) }
    }

    @Test func inheritedChildTasksKeepRootSessionAndEditsAreSerialized() async throws {
        let fixture = FileSystemClientFixture(files: ["/tmp/file.swift": "0"])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let access = harness.client.access(sessionID: "root-not-child") { true }
        try await ClientTextFileSystem.$current.withValue(access) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask(name: "Delegated client edit") {
                        let edit = try #require(ClientTextFileSystem.current?.edit)
                        _ = try await edit(URL(fileURLWithPath: "/tmp/file.swift")) { String((Int($0) ?? 0) + 1) }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(await fixture.text(at: "/tmp/file.swift") == "8")
        #expect(
            await fixture.requests.allSatisfy {
                $0.objectValue?["params"]?.objectValue?["sessionId"] == .string("root-not-child")
            })
        #expect(ClientTextFileSystem.current == nil)
    }

    @Test func directExecutorStillEnforcesGrantsAndLocalFallbackRemainsAvailable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FileSystemClientFixture(files: [:])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let executor = DirectToolExecutor(
            mcpRuntime: DirectMCPToolRuntime(),
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in ClientFileSystemTestBackend() })
        let call = DirectAgentToolCall(
            id: "write", name: "local.writeFile",
            argumentsObject: ["path": "Local.swift", "content": "local"],
            argumentsJSON: #"{"path":"Local.swift","content":"local"}"#)
        await ClientTextFileSystem.$current.withValue(harness.client.access(sessionID: "root") { true }) {
            let result = await executor.execute(
                sessionID: "root", toolCall: call, workingDirectory: root, allowedToolNames: [])
            #expect(result.status == .permissionDenied)
        }
        #expect(await fixture.requests.isEmpty)
        let result = await executor.execute(
            sessionID: "root", toolCall: call, workingDirectory: root, allowedToolNames: ["local.writeFile"])
        #expect(result.status == .completed)
        #expect(try String(contentsOf: root.appendingPathComponent("Local.swift"), encoding: .utf8) == "local")
        await executor.shutdown()
    }

    @Test func realBridgePromptInjectsClientAccessAndEmitsDiff() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("File.swift")
        let fixture = FileSystemClientFixture(files: [file.path: "before"])
        let harness = FileSystemHarness(fixture: fixture)
        defer { harness.stop() }
        let backend = ClientFileSystemTestBackend()
        let config = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [.init(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
            runMode: .acp, workingDirectory: root, appMode: false)
        let bridge = ZenCODEACPBridge(
            configuration: config, writer: harness.writer, backendFactory: { _, _ in backend })
        try await bridge.initialize(
            id: .string("init"), params: ["clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true]]])
        try await bridge.newSession(id: .string("new"), params: ["cwd": root.path, "allowedTools": ["local.editFile"]])
        let sessionID = try #require(await bridge.clientFileSystemTestSessionID())
        try await bridge.prompt(
            id: .string("prompt"), params: ["sessionId": sessionID, "prompt": "edit the client file"])
        #expect(await backend.sawClientContext)
        #expect(await fixture.text(at: file.path) == "after")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let diffs = harness.captured().flatMap { message in
            message.objectValue?["params"]?.objectValue?["update"]?.objectValue?["content"]?.arrayValue ?? []
        }.filter { $0.objectValue?["type"] == .string("diff") }
        #expect(diffs.count == 1)
        #expect(diffs.first?.objectValue?["path"] == .string(file.path))
        #expect(diffs.first?.objectValue?["oldText"] == .string("before"))
        #expect(diffs.first?.objectValue?["newText"] == .string("after"))
        let staleAccess = try #require(await bridge.clientFileSystemTestAccess(sessionID: sessionID))
        try await bridge.close(id: .string("close"), params: ["sessionId": sessionID])
        let countAfterClose = await fixture.requests.count
        await #expect(throws: CancellationError.self) { _ = try await staleAccess.read?(file) }
        #expect(await fixture.requests.count == countAfterClose)
        await bridge.shutdown()
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func invoke(_ name: String, _ arguments: [String: Any], root: URL) async throws -> String {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == name })
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await tool.invoke(inputData: data, context: FeatureContext(workingDirectory: root))
        return try JSONDecoder().decode(String.self, from: output)
    }
}

private struct FileSystemHarness {
    let writer: ACPWriter
    let client: ACPClientFileSystem
    let continuation: AsyncStream<JSONValue>.Continuation
    let pump: Task<Void, Never>
    let captured: @Sendable () -> [JSONValue]

    init(fixture: FileSystemClientFixture, timeout: Duration = .seconds(5)) {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let wire = Mutex<[JSONValue]>([])
        self.captured = { wire.withLock { $0 } }
        let writer = ACPWriter { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                wire.withLock { $0.append(value) }
                continuation.yield(value)
            }
        }
        self.writer = writer
        self.client = ACPClientFileSystem(writer: writer, canRead: true, canWrite: true, timeout: timeout)
        self.continuation = continuation
        self.pump = Task(name: "Filesystem client test peer") {
            for await message in stream {
                if let reply = await fixture.response(to: message) { await writer.handleResponse(reply) }
            }
        }
    }
    func stop() {
        continuation.finish()
        pump.cancel()
    }
}

private actor FileSystemClientFixture {
    enum Behavior { case normal, deny, denyWrite, malformedRead, changeBeforeWrite, changeAfterWrite, stall }
    private var files: [String: String]
    private let behavior: Behavior
    private var readCount = 0
    private(set) var requests: [JSONValue] = []
    private(set) var writeCount = 0

    init(files: [String: String], behavior: Behavior = .normal) {
        self.files = files
        self.behavior = behavior
    }
    func text(at path: String) -> String? { files[path] }
    func response(to message: JSONValue) -> JSONValue? {
        guard let object = message.objectValue,
            let method = object["method"]?.stringValue, method.hasPrefix("fs/"),
            let id = object["id"], let params = object["params"]?.objectValue,
            let path = params["path"]?.stringValue
        else { return nil }
        requests.append(message)
        if behavior == .stall { return nil }
        if behavior == .deny || (behavior == .denyWrite && method == "fs/write_text_file") { return error(id) }
        let result: JSONValue
        if method == "fs/read_text_file" {
            readCount += 1
            if behavior == .malformedRead {
                result = .object(["content": .number(7)])
            } else if behavior == .changeBeforeWrite, readCount > 1 {
                result = .object(["content": .string("external")])
            } else if behavior == .changeAfterWrite, writeCount > 0 {
                result = .object(["content": .string("external")])
            } else if let text = files[path] {
                result = .object(["content": .string(text)])
            } else {
                return error(id)
            }
        } else {
            guard let text = params["content"]?.stringValue else { return error(id) }
            writeCount += 1
            files[path] = text
            result = .null
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    private func error(_ id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(-32000), "message": .string("Client file unavailable")]),
        ])
    }
}

private actor ClientFileSystemTestBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var sawClientContext = false
    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = .init(
            sessionID: id, workingDirectoryPath: cwd, systemPrompt: systemPrompt,
            cacheKey: cacheKey, history: history, allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection, preserveThinking: preserveThinking
        )
    }
    func updateSessionOptions(
        id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {}
    func closeSession(id: String) { sessions.removeValue(forKey: id) }
    func shutdown() { sessions.removeAll() }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String {
        "test-model"
    }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { sessions[id] }
    func sendPrompt(
        sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sawClientContext = ClientTextFileSystem.current != nil
        let session = try #require(sessions[sessionID])
        let executor = DirectToolExecutor(
            mcpRuntime: DirectMCPToolRuntime(),
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in ClientFileSystemTestBackend() })
        let call = DirectAgentToolCall(
            id: "client-edit", name: "local.editFile",
            argumentsObject: ["path": "File.swift", "old": "before", "new": "after"],
            argumentsJSON: #"{"path":"File.swift","old":"before","new":"after"}"#)
        await onEvent(.toolCallStarted(call))
        let result = await executor.execute(
            sessionID: sessionID, toolCall: call,
            workingDirectory: URL(fileURLWithPath: session.workingDirectoryPath),
            allowedToolNames: session.allowedToolNames)
        #expect(result.status == .completed)
        #expect(result.fileChanges.count == 1)
        await onEvent(.toolCallCompleted(call, result))
        await executor.shutdown()
        return .init(text: "done", stopReason: "end_turn", modelID: "test-model")
    }
}

extension ZenCODEACPBridge {
    fileprivate func clientFileSystemTestSessionID() -> String? { sessions.keys.first }
    fileprivate func clientFileSystemTestAccess(sessionID: String) -> ClientTextFileSystem? {
        guard let epoch = sessions[sessionID]?.epoch else { return nil }
        return clientFileSystem?.access(sessionID: sessionID) {
            await self.canUseClientFileSystem(sessionID: sessionID, epoch: epoch)
        }
    }
}
