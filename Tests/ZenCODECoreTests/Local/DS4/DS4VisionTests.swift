//
//  DS4VisionTests.swift
//  ZenCODE
//
//  Vision on the in-process DS4 path (no library, no model): the temporary
//  image files (`DS4ImageStaging`), the multimodal rendering of user messages
//  and tool observations (`DS4TranscriptRenderer`), the single tokenization of
//  a round (`DS4Engine.prepare` + `sync(sessionID:prepared:)`) and the client
//  flow with `MockDS4Engine`: images present, absent (no vision encoder),
//  unreadable / unencodable, cancellation, and the refused KV checkpoint.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Support

private enum VisionSupport {
    static let png = RemoteGenerationClientDS4EngineTests.pngAttachment
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    static let noVisionDiagnostic = "DS4 model has no vision encoder configured; images were ignored"

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-vision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func dataURL(_ data: Data = pngBytes, contentType: String = "image/png") -> String {
        "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// File names in `directory`, `[]` when it does not exist.
    static func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func permissions(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    struct Multimodal: Equatable {
        let role: String
        let textParts: [String]
        let imageFiles: [URL]
    }

    static func multimodalMessages(in transcript: [DS4TranscriptOperation]) -> [Multimodal] {
        transcript.compactMap { operation in
            guard case let .multimodalMessage(role, textParts, imageFiles) = operation else {
                return nil
            }
            return Multimodal(role: role, textParts: textParts, imageFiles: imageFiles)
        }
    }

    static func message(_ role: String, _ content: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = ["role": role, "content": content]
        for (key, value) in extra {
            message[key] = value
        }
        return message
    }

    /// Chat-completions content items: one text item, then one `image_url` per image.
    static func content(_ text: String?, images: [String]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if let text {
            items.append(["type": "text", "text": text])
        }
        items.append(contentsOf: images.map { ["type": "image_url", "image_url": ["url": $0]] })
        return items
    }

    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

/// Maps `image_url`s to fixed files, for rendering tests.
private struct FakeImageResolver: DS4ImageFileResolving {
    let files: [String: URL]

    func imageFile(forImageURL imageURL: String) -> URL? {
        files[imageURL]
    }
}

// MARK: - Staging

@Suite("DS4 image staging", .serialized)
struct DS4VisionImageStagingTests {
    @Test
    func theDefaultDirectoryIsUnderTheSupportDirectory() {
        let support = URL(fileURLWithPath: "/tmp/zencode-support", isDirectory: true)

        #expect(DS4ImageStaging.directory(supportDirectory: support).path == "/tmp/zencode-support/ds4/tmp")
    }

    @Test
    func aDataURLIsDecodedIntoAPrivateTemporaryFileAndRemoved() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ds4/tmp", isDirectory: true)
        let staging = DS4ImageStaging(directory: directory)
        let imageURL = VisionSupport.dataURL()

        let file = try #require(staging.imageFile(forImageURL: imageURL))

        #expect(VisionSupport.sameDirectory(file.deletingLastPathComponent(), directory))
        #expect(file.pathExtension == "png")
        #expect(UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil)
        #expect(try Data(contentsOf: file) == VisionSupport.pngBytes)
        #expect(VisionSupport.permissions(of: directory) == 0o700)
        #expect(VisionSupport.permissions(of: file) == 0o600)
        // The same image is the same file for the whole round.
        #expect(staging.imageFile(forImageURL: imageURL) == file)
        #expect(staging.stagedFiles == [file])
        let other = try #require(staging.imageFile(forImageURL: VisionSupport.dataURL(Data([1, 2, 3]))))
        #expect(other != file)

        staging.removeAll()

        #expect(!VisionSupport.exists(file))
        #expect(!VisionSupport.exists(other))
        #expect(staging.stagedFiles.isEmpty)
        #expect(VisionSupport.contents(of: directory).isEmpty)
        staging.removeAll()
    }

    @Test
    func jpegKeepsAnImageExtension() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = DS4ImageStaging(directory: root.appendingPathComponent("tmp"))

        let file = try #require(staging.imageFile(
            forImageURL: VisionSupport.dataURL(Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        ))

        #expect(["jpg", "jpeg"].contains(file.pathExtension))
        staging.removeAll()
    }

    @Test
    func localFilesAreCopiedAndTheSourceIsKept() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try VisionSupport.write(VisionSupport.pngBytes, named: "shot.png", in: root)
        let directory = root.appendingPathComponent("tmp")
        let staging = DS4ImageStaging(directory: directory)

        let fromPath = try #require(staging.imageFile(forImageURL: source.path))
        let fromFileURL = try #require(staging.imageFile(forImageURL: source.absoluteString))

        #expect(fromPath != source)
        #expect(fromPath.pathExtension == "png")
        #expect(try Data(contentsOf: fromPath) == VisionSupport.pngBytes)
        #expect(try Data(contentsOf: fromFileURL) == VisionSupport.pngBytes)
        staging.removeAll()
        #expect(!VisionSupport.exists(fromPath))
        #expect(VisionSupport.exists(source))
    }

    @Test
    func unreadableImagesAreReportedOnceAndNothingIsLeftBehind() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("tmp")
        let staging = DS4ImageStaging(directory: directory)
        let unreadable = [
            "data:image/png;base64,",
            "data:image/png;base64,@@@@",
            "https://example.com/image.png",
            "relative/image.png",
            root.appendingPathComponent("missing.png").path,
            root.path,
        ]

        for imageURL in unreadable {
            #expect(staging.imageFile(forImageURL: imageURL) == nil)
        }
        // Asking again does not count the same image twice.
        #expect(staging.imageFile(forImageURL: unreadable[0]) == nil)

        #expect(staging.failedImageCount == unreadable.count)
        #expect(staging.takeNewFailureCount() == unreadable.count)
        #expect(staging.takeNewFailureCount() == 0)
        #expect(staging.stagedFiles.isEmpty)
        #expect(VisionSupport.contents(of: directory).isEmpty)
    }

    @Test
    func theFirstUseSweepsOnlyStaleFilesOfPreviousRuns() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = try VisionSupport.write(Data([1]), named: "\(UUID().uuidString.lowercased()).png", in: directory)
        let recent = try VisionSupport.write(Data([2]), named: "\(UUID().uuidString.lowercased()).png", in: directory)
        let foreign = try VisionSupport.write(Data([3]), named: "notes.txt", in: directory)
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: foreign.path)
        let staging = DS4ImageStaging(directory: directory)

        let file = try #require(staging.imageFile(forImageURL: VisionSupport.dataURL()))

        #expect(!VisionSupport.exists(stale))
        #expect(VisionSupport.exists(recent))
        // Only `<UUID>[.ext]` files are ever deleted.
        #expect(VisionSupport.exists(foreign))
        #expect(VisionSupport.exists(file))
        staging.removeAll()
        #expect(VisionSupport.exists(recent))
    }

    @Test
    func stalenessIsMeasuredFromTheModificationDate() throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try VisionSupport.write(Data([1]), named: "\(UUID().uuidString.lowercased()).png", in: root)

        DS4ImageStaging.removeStaleFiles(in: root, now: Date().addingTimeInterval(1800))
        #expect(VisionSupport.exists(file))

        DS4ImageStaging.removeStaleFiles(in: root, now: Date().addingTimeInterval(DS4ImageStaging.staleFileAge + 60))
        #expect(!VisionSupport.exists(file))
    }
}

// MARK: - Rendering

@Suite("DS4 vision rendering")
struct DS4VisionRendererTests {
    private let first = URL(fileURLWithPath: "/tmp/ds4/tmp/first.png")
    private let second = URL(fileURLWithPath: "/tmp/ds4/tmp/second.png")
    private let third = URL(fileURLWithPath: "/tmp/ds4/tmp/third.png")

    private func context(_ resolver: (any DS4ImageFileResolving)?) -> DS4TranscriptRenderer.Context {
        DS4TranscriptRenderer.Context(
            syntax: .dsml41,
            thinkMode: DS4EngineABI.ThinkMode.none,
            toolsPrompt: "",
            preserveThinking: false,
            imageFiles: resolver
        )
    }

    private var resolver: FakeImageResolver {
        FakeImageResolver(files: ["img-1": first, "img-2": second, "img-3": third])
    }

    private var toolRound: [[String: Any]] {
        [
            VisionSupport.message("system", "sys"),
            VisionSupport.message("user", "go"),
            VisionSupport.message("assistant", "", extra: [
                "tool_calls": [
                    ["id": "c1", "type": "function", "function": ["name": "a", "arguments": "{}"]],
                    ["id": "c2", "type": "function", "function": ["name": "b", "arguments": "{}"]],
                    ["id": "c3", "type": "function", "function": ["name": "c", "arguments": "{}"]],
                ],
            ]),
            VisionSupport.message("tool", "out a", extra: ["tool_call_id": "c1", "name": "a"]),
            VisionSupport.message(
                "tool", VisionSupport.content("shot b", images: ["img-1"]),
                extra: ["tool_call_id": "c2", "name": "b"]
            ),
            VisionSupport.message(
                "tool", VisionSupport.content(nil, images: ["img-2", "img-3"]),
                extra: ["tool_call_id": "c3", "name": "c"]
            ),
        ]
    }

    @Test
    func aUserMessageWithImagesBecomesOneMultimodalUserMessage() {
        let messages = [
            VisionSupport.message("system", "sys"),
            VisionSupport.message("user", VisionSupport.content("What is this?", images: ["img-1", "img-2"])),
        ]

        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context(resolver))

        #expect(VisionSupport.multimodalMessages(in: rendered.operations) == [
            .init(role: "user", textParts: ["What is this?", "", ""], imageFiles: [first, second]),
        ])
        #expect(!rendered.operations.contains(.message(role: "user", content: "What is this?")))
    }

    @Test
    func theFrozenUserContentIsTheTextOfTheMultimodalMessage() {
        let messages = [
            VisionSupport.message(
                "user",
                VisionSupport.content("What is this?", images: ["img-1"]),
                extra: [DS4MessageKeys.userContent: "What is this?\n\nMEMORY"]
            ),
        ]

        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context(resolver))

        #expect(VisionSupport.multimodalMessages(in: rendered.operations) == [
            .init(role: "user", textParts: ["What is this?\n\nMEMORY", ""], imageFiles: [first]),
        ])
    }

    @Test
    func theObservationOfARoundWithImagesIsOneMultimodalUserMessageWithTheSameText() throws {
        let rendered = DS4TranscriptRenderer.render(messages: toolRound, context: context(resolver))
        let textOnly = DS4TranscriptRenderer.render(messages: toolRound, context: context(nil))

        let observation = try #require(VisionSupport.multimodalMessages(in: rendered.operations).first)
        #expect(observation.role == "user")
        #expect(observation.imageFiles == [first, second, third])
        // The images follow the text of the result that returned them.
        #expect(observation.textParts == [
            "Tool result 1 (a):\nout a\nTool result 2 (b):\nshot b\n",
            "Tool result 3 (c):\n",
            "",
            "",
        ])
        guard case let .message(role, text) = try #require(textOnly.operations.dropLast().last) else {
            Issue.record("expected the text-only observation")
            return
        }
        #expect(role == "tool")
        #expect(observation.textParts.joined() == text)
        #expect(VisionSupport.multimodalMessages(in: rendered.operations).count == 1)
    }

    @Test
    func aRoundWithoutImagesKeepsTheToolRole() {
        let messages = Array(toolRound.prefix(4))

        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context(resolver))

        #expect(VisionSupport.multimodalMessages(in: rendered.operations).isEmpty)
        #expect(rendered.operations.contains(.message(role: "tool", content: "Tool result 1 (a):\nout a\n")))
    }

    @Test
    func withoutAVisionEncoderImagesAreLeftOut() {
        let messages = [
            VisionSupport.message("user", VisionSupport.content("Look", images: ["img-1"])),
        ] + Array(toolRound.dropFirst(2))

        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context(nil))

        #expect(VisionSupport.multimodalMessages(in: rendered.operations).isEmpty)
        #expect(rendered.operations.contains(.message(role: "user", content: "Look")))
    }

    @Test
    func imagesThatCannotBeResolvedAreSkipped() {
        let partial = FakeImageResolver(files: ["img-2": second])
        let messages = [
            VisionSupport.message("user", VisionSupport.content("Look", images: ["img-1", "img-2"])),
            VisionSupport.message("user", VisionSupport.content("Again", images: ["img-1"])),
        ]

        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context(partial))

        #expect(VisionSupport.multimodalMessages(in: rendered.operations) == [
            .init(role: "user", textParts: ["Look", ""], imageFiles: [second]),
        ])
        #expect(rendered.operations.contains(.message(role: "user", content: "Again")))
    }

    @Test
    func renderingIsDeterministicAcrossRounds() {
        let once = DS4TranscriptRenderer.render(messages: toolRound, context: context(resolver))
        let twice = DS4TranscriptRenderer.render(messages: toolRound, context: context(resolver))

        #expect(once.operations == twice.operations)
        #expect(once.reminderAnchorOperationCount == twice.reminderAnchorOperationCount)
    }
}

// MARK: - Engine API

@Suite("DS4 prepared transcripts", .serialized)
struct DS4VisionPreparedTranscriptTests {
    private func engine(hasVision: Bool = true) -> MockDS4Engine {
        MockDS4Engine(
            configuration: .mock(contextSize: 8192),
            info: DS4EngineInfo(
                modelName: "mock-ds4",
                modelID: 41,
                routedQuantBits: 2,
                hasVision: hasVision,
                toolSyntaxID: DS4EngineABI.ToolSyntax.dsml41,
                mtpDraftTokens: 1,
                contextSize: 8192
            )
        )
    }

    private func transcript(image: URL) -> [DS4TranscriptOperation] {
        [
            .begin,
            .message(role: "system", content: "sys"),
            .multimodalMessage(role: "user", textParts: ["Look", ""], imageFiles: [image]),
            .assistantPrefix(mode: 0),
        ]
    }

    private func withImage(_ body: (URL) async throws -> Void) async throws {
        let root = try VisionSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(VisionSupport.write(VisionSupport.pngBytes, named: "i.png", in: root))
    }

    @Test
    func countingThenSyncingEncodesEachImageTwiceButPreparingOnce() async throws {
        try await withImage { image in
            let ops = transcript(image: image)
            let legacy = engine()
            _ = try await legacy.tokenCount(of: ops)
            _ = try await legacy.sync(sessionID: "s", transcript: ops, onProgress: { _, _, _ in })
            #expect(legacy.imageEncodes.count == 2)

            let prepared = engine()
            let transcript = try await prepared.prepare(transcript: ops)
            let sync = try await prepared.sync(sessionID: "s", prepared: transcript, onProgress: { _, _, _ in })
            transcript.release()

            #expect(prepared.imageEncodes.count == 1)
            #expect(sync.tokenCount == transcript.tokenCount)
            #expect(sync.tokenCount == MockDS4Engine.tokenCount(of: ops))
            #expect(prepared.livePreparedCount == 0)
        }
    }

    @Test
    func tokenCountsAfterEachOperationLocateAPositionWithoutTokenizingAPrefix() async throws {
        try await withImage { image in
            let ops = transcript(image: image)
            let mock = engine()

            let prepared = try await mock.prepare(transcript: ops)

            #expect(prepared.operationTokenCounts?.count == ops.count)
            #expect(prepared.tokenCount(afterOperations: 0) == 0)
            for count in 1...ops.count {
                #expect(prepared.tokenCount(afterOperations: count) == MockDS4Engine.tokenCount(of: Array(ops.prefix(count))))
            }
            #expect(prepared.tokenCount(afterOperations: ops.count + 1) == nil)
            #expect(prepared.tokenCount(afterOperations: -1) == nil)
            #expect(prepared.tokenCount == prepared.tokenCount(afterOperations: ops.count))
            prepared.release()
        }
    }

    @Test
    func aTranscriptPreparedByAnotherEngineIsTokenizedAgain() async throws {
        try await withImage { image in
            let ops = transcript(image: image)
            let producer = engine()
            let consumer = engine()
            let prepared = try await producer.prepare(transcript: ops)

            let sync = try await consumer.sync(sessionID: "s", prepared: prepared, onProgress: { _, _, _ in })

            #expect(sync.tokenCount == MockDS4Engine.tokenCount(of: ops))
            #expect(producer.imageEncodes.count == 1)
            #expect(consumer.imageEncodes.count == 1)
            prepared.release()
        }
    }

    @Test
    func aReleasedTranscriptIsTokenizedAgain() async throws {
        try await withImage { image in
            let ops = transcript(image: image)
            let mock = engine()
            let prepared = try await mock.prepare(transcript: ops)
            prepared.release()

            _ = try await mock.sync(sessionID: "s", prepared: prepared, onProgress: { _, _, _ in })

            #expect(mock.imageEncodes.count == 2)
        }
    }

    @Test
    func releaseIsIdempotentAndADroppedTranscriptReleasesItself() async throws {
        try await withImage { image in
            let mock = engine()
            let prepared = try await mock.prepare(transcript: transcript(image: image))
            #expect(mock.livePreparedCount == 1)

            prepared.release()
            prepared.release()

            #expect(mock.livePreparedCount == 0)
            #expect(mock.releasedPreparedCount == 1)

            var dropped: DS4PreparedTranscript? = try await mock.prepare(transcript: transcript(image: image))
            #expect(mock.livePreparedCount == 1)
            #expect(dropped != nil)
            dropped = nil
            #expect(mock.livePreparedCount == 0)
            #expect(mock.releasedPreparedCount == 2)
        }
    }

    @Test
    func aFailedEncodeDoesNotLeakAPreparedTranscript() async throws {
        let mock = engine()
        let missing = URL(fileURLWithPath: "/nonexistent/zencode-ds4/missing.png")

        await #expect(throws: DS4EngineError.self) {
            _ = try await mock.prepare(transcript: self.transcript(image: missing))
        }

        #expect(mock.livePreparedCount == 0)
        #expect(mock.releasedPreparedCount == 0)
    }

    @Test
    func theNativeTokenBufferIsFreedOnceOnTheEngineThread() {
        let raw = UnsafeMutableRawPointer(bitPattern: 0x1000)!
        let freed = DS4TestBox<[UInt]>([])
        let queued = DS4TestBox<[@Sendable () -> Void]>([])
        let accepting = DS4TestBox(true)
        func makeBuffer() -> DS4NativeTokenBuffer {
            DS4NativeTokenBuffer(
                handle: raw,
                free: { handle in freed.update { $0.append(UInt(bitPattern: handle.raw)) } },
                submit: { job in
                    guard accepting.value else {
                        return false
                    }
                    queued.update { $0.append(job) }
                    return true
                }
            )
        }

        let buffer = makeBuffer()
        #expect(buffer.liveHandle == raw)
        #expect(!buffer.isReleased)
        buffer.release()
        buffer.release()

        // Released: not usable any more, freed by the queued job, once.
        #expect(buffer.isReleased)
        #expect(buffer.liveHandle == nil)
        #expect(freed.value.isEmpty)
        #expect(queued.value.count == 1)
        queued.value.forEach { $0() }
        #expect(freed.value == [UInt(bitPattern: raw)])

        // Engine thread stopped: freed in place.
        accepting.update { $0 = false }
        let orphan = makeBuffer()
        orphan.release()
        #expect(freed.value.count == 2)

        // Dropped without release.
        accepting.update { $0 = true }
        queued.update { $0.removeAll() }
        do {
            _ = makeBuffer()
        }
        #expect(queued.value.count == 1)
    }
}

// MARK: - Client

@Suite("DS4 vision client", .serialized)
struct DS4VisionClientTests {
    private struct Setup {
        let harness: DS4ClientHarness
        let client: RemoteGenerationClient
        /// `<support>/ds4/tmp` of this test.
        let tmp: URL
    }

    private func withClient(
        hasVision: Bool = true,
        visionRelativePath: String? = "vision.gguf",
        syncDelay: Duration = .zero,
        contextSize: Int = 8192,
        history: [AgentRuntimeMessage] = [],
        _ body: (Setup) async throws -> Void
    ) async throws {
        let harness = try DS4ClientHarness(
            contextSize: contextSize,
            hasVision: hasVision,
            visionRelativePath: visionRelativePath,
            syncDelay: syncDelay
        )
        let support = harness.base.appendingPathComponent("support", isDirectory: true)
        let tmp = DS4ImageStaging.directory(supportDirectory: support)
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let client = try await harness.makeClient(history: history)
            do {
                try await body(Setup(harness: harness, client: client, tmp: tmp))
            } catch {
                await client.shutdown()
                throw error
            }
            await client.shutdown()
        }
    }

    private func screenshotHistory() -> [AgentRuntimeMessage] {
        [
            AgentRuntimeMessage(role: .user, content: "Capture the screen"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentRuntimeToolCall(id: "call_1", name: DS4ClientHarness.toolName, argumentsJSON: "{}")]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: "Screenshot captured",
                attachments: [VisionSupport.png],
                toolCallID: "call_1",
                toolName: DS4ClientHarness.toolName
            ),
        ]
    }

    // MARK: Images present

    @Test
    func aUserImageIsEncodedOnceFromAPrivateTemporaryFileThatIsRemoved() async throws {
        try await withClient { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["seen"])
            let recorder = DS4EventRecorder()

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Look", attachments: [VisionSupport.png], onEvent: recorder.handler
            )

            let transcript = try #require(harness.engine.transcripts.first)
            let multimodal = try #require(VisionSupport.multimodalMessages(in: transcript).first)
            #expect(multimodal.role == "user")
            #expect(multimodal.textParts == ["Look", ""])
            let file = try #require(multimodal.imageFiles.first)
            #expect(multimodal.imageFiles.count == 1)
            #expect(VisionSupport.sameDirectory(file.deletingLastPathComponent(), setup.tmp))
            #expect(file.pathExtension == "png")
            #expect(UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil)

            // One encode although the round counts the prompt and syncs it.
            let encodes = harness.mock.imageEncodes
            #expect(encodes.count == 1)
            #expect(encodes.first?.byteCount == VisionSupport.pngBytes.count)
            #expect(encodes.first?.directoryPermissions == 0o700)
            #expect(harness.mock.calls.filter { $0 == .prepare }.count == 1)
            // No temporary file and no prepared transcript survive the round.
            #expect(!VisionSupport.exists(file))
            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)
            #expect(harness.mock.livePreparedCount == 0)
            #expect(harness.mock.releasedPreparedCount == 1)
            // The image stays in the conversation; nothing is reported.
            let snapshot = try #require(await setup.client.snapshotSession(id: "session"))
            #expect(snapshot.history.first?.attachments.count == 1)
            #expect(!recorder.diagnostics.contains { $0.contains("images were") || $0.contains("attached images") })
        }
    }

    @Test
    func aToolImageMakesTheObservationAUserMessageAndTheNextRoundReusesThePrefix() async throws {
        try await withClient(history: screenshotHistory()) { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["A window."])
            harness.mock.enqueueGeneration(["Still a window."])

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "What do you see?", attachments: [], onEvent: { _ in }
            )
            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "And now?", attachments: [], onEvent: { _ in }
            )

            let transcripts = harness.engine.transcripts
            try #require(transcripts.count == 2)
            let observations = transcripts.map(VisionSupport.multimodalMessages(in:))
            for observation in observations {
                #expect(observation.count == 1)
                #expect(observation.first?.role == "user")
                #expect(observation.first?.textParts == ["Tool result 1 (fixture.echo):\nScreenshot captured\n", ""])
                #expect(observation.first?.imageFiles.count == 1)
            }
            // Not also rendered as a text-only tool message.
            for transcript in transcripts {
                #expect(!transcript.contains { operation in
                    if case let .message(role, _) = operation { role == "tool" } else { false }
                })
            }
            // Same rendering, new temporary files: the prefix is still reused.
            #expect(observations[0].first?.imageFiles != observations[1].first?.imageFiles)
            let syncs = harness.engine.syncs
            try #require(syncs.count == 2)
            let generated = try #require(harness.engine.results.first).tokens
            #expect(syncs[0].cached == 0)
            #expect(syncs[1].cached == syncs[0].cached + syncs[0].suffix + generated.count)
            #expect(syncs[1].cached > 0)
            // Each round encodes its images once and leaves no file behind.
            #expect(harness.mock.imageEncodes.count == 2)
            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)
            #expect(harness.mock.livePreparedCount == 0)
        }
    }

    @Test
    func aRoundWithoutImagesKeepsTheToolRoleAndNeverTouchesTheTemporaryDirectory() async throws {
        try await withClient { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["Let me check.", DS4ClientHarness.dsml41EchoCall("hi")])
            harness.mock.enqueueGeneration(["Done"])

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Echo hi", attachments: [], onEvent: { _ in }
            )

            let second = try #require(harness.engine.transcripts.last)
            #expect(second.contains { operation in
                if case let .message(role, content) = operation {
                    role == "tool" && content.hasPrefix("Tool result 1 (fixture.echo):\n")
                } else {
                    false
                }
            })
            #expect(harness.engine.transcripts.allSatisfy { VisionSupport.multimodalMessages(in: $0).isEmpty })
            #expect(harness.mock.imageEncodes.isEmpty)
            #expect(!VisionSupport.exists(setup.tmp))
        }
    }

    @Test
    func reminderPositionIsLocatedWithoutEncodingTheImagesAgain() async throws {
        let history = [
            AgentRuntimeMessage(role: .user, content: "hi", attachments: [VisionSupport.png]),
            AgentRuntimeMessage(role: .assistant, content: "hello"),
            AgentRuntimeMessage(role: .user, content: String(repeating: "x", count: 210_000)),
            AgentRuntimeMessage(role: .assistant, content: "ok"),
        ]
        try await withClient(contextSize: 400_000, history: history) { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["one"])
            let recorder = DS4EventRecorder()

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "next", attachments: [], onEvent: recorder.handler
            )

            #expect(recorder.statuses.contains("Re-injecting system prompt reminder..."))
            // The anchor comes from the counts recorded by `prepare`; the only
            // `tokenCount` call is the compaction reserve (text only).
            #expect(harness.mock.calls.filter { $0 == .tokenCount }.count == 1)
            // One encode for the first tokenization, one for the re-render
            // that places the reminder.
            #expect(harness.mock.imageEncodes.count == 2)
            #expect(harness.mock.livePreparedCount == 0)
            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)
        }
    }

    // MARK: Images absent

    private struct VisionSetup: Sendable, CustomTestStringConvertible {
        let hasVision: Bool
        let visionRelativePath: String?
        var testDescription: String {
            "hasVision \(hasVision), vision path \(visionRelativePath ?? "nil")"
        }
    }

    @Test(arguments: [
        VisionSetup(hasVision: false, visionRelativePath: nil),
        VisionSetup(hasVision: true, visionRelativePath: nil),
        VisionSetup(hasVision: false, visionRelativePath: "vision.gguf"),
    ])
    private func imagesAreRemovedWithOneDiagnosticPerTurnWithoutAVisionEncoder(_ setup: VisionSetup) async throws {
        try await withClient(hasVision: setup.hasVision, visionRelativePath: setup.visionRelativePath) { context in
            let harness = context.harness
            harness.mock.enqueueGeneration(["Let me check.", DS4ClientHarness.dsml41EchoCall("hi")])
            harness.mock.enqueueGeneration(["Done"])
            let recorder = DS4EventRecorder()

            _ = try await context.client.sendPrompt(
                sessionID: "session", prompt: "Look", attachments: [VisionSupport.png], onEvent: recorder.handler
            )

            // Reported once even though the turn has two rounds.
            #expect(recorder.diagnostics.filter { $0 == VisionSupport.noVisionDiagnostic }.count == 1)
            let snapshot = try #require(await context.client.snapshotSession(id: "session"))
            #expect(snapshot.history.first?.attachments.isEmpty == true)
            #expect(harness.engine.transcripts.count == 2)
            #expect(harness.engine.transcripts.allSatisfy { VisionSupport.multimodalMessages(in: $0).isEmpty })
            #expect(harness.engine.transcripts.first?.contains(.message(role: "user", content: "Look")) == true)
            #expect(harness.mock.imageEncodes.isEmpty)
            #expect(!VisionSupport.exists(context.tmp))
        }
    }

    // MARK: Images that cannot be used

    @Test
    func anImageTheEngineCannotEncodeIsRemovedAndLaterTurnsKeepWorking() async throws {
        try await withClient { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["text only"])
            harness.mock.enqueueGeneration(["seen"])
            harness.mock.failImageEncoding = true
            let recorder = DS4EventRecorder()

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Look", attachments: [VisionSupport.png], onEvent: recorder.handler
            )

            let diagnostic = try #require(recorder.diagnostics.first { $0.hasPrefix("DS4 could not use the attached images") })
            #expect(diagnostic.contains("unsupported image format"))
            #expect(diagnostic.hasSuffix("images were ignored"))
            let snapshot = try #require(await setup.client.snapshotSession(id: "session"))
            #expect(snapshot.history.first?.attachments.isEmpty == true)
            let transcript = try #require(harness.engine.transcripts.first)
            #expect(VisionSupport.multimodalMessages(in: transcript).isEmpty)
            #expect(transcript.contains(.message(role: "user", content: "Look")))
            #expect(harness.mock.livePreparedCount == 0)
            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)

            // The session is not stuck with the bad image.
            harness.mock.failImageEncoding = false
            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Try again", attachments: [VisionSupport.png], onEvent: { _ in }
            )
            let retry = try #require(harness.engine.transcripts.last)
            #expect(VisionSupport.multimodalMessages(in: retry).count == 1)
            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)
        }
    }

    @Test
    func anImageThatCannotBeReadIsRemovedBeforeTheEngineSeesIt() async throws {
        let empty = AgentRuntimeAttachment(
            kind: .image, data: Data(), contentType: "image/png", originalFilename: "empty.png"
        )
        try await withClient { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["ok"])
            let recorder = DS4EventRecorder()

            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Look", attachments: [empty], onEvent: recorder.handler
            )

            #expect(recorder.diagnostics.contains(
                "DS4 could not use the attached images (cannot read an attached image); images were ignored"
            ))
            let transcript = try #require(harness.engine.transcripts.first)
            #expect(VisionSupport.multimodalMessages(in: transcript).isEmpty)
            #expect(harness.mock.imageEncodes.isEmpty)
            let snapshot = try #require(await setup.client.snapshotSession(id: "session"))
            #expect(snapshot.history.first?.attachments.isEmpty == true)
        }
    }

    // MARK: Cancellation

    @Test
    func cancellingTheSyncRemovesTheTemporaryFilesAndTheTokenBuffer() async throws {
        try await withClient(syncDelay: .seconds(30)) { setup in
            let harness = setup.harness
            let client = setup.client
            let task = Task {
                try await client.sendPrompt(
                    sessionID: "session", prompt: "Look", attachments: [VisionSupport.png], onEvent: { _ in }
                )
            }
            await ds4Eventually { await harness.registry.activeLeaseSessionID == "session" }
            // While the engine works on the prompt, the file it encodes is there.
            #expect(VisionSupport.contents(of: setup.tmp).count == 1)
            #expect(harness.mock.livePreparedCount == 1)

            task.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }

            #expect(VisionSupport.contents(of: setup.tmp).isEmpty)
            #expect(harness.mock.livePreparedCount == 0)
            #expect(harness.mock.releasedPreparedCount == 1)
            #expect(await harness.registry.isGenerationLockHeld == false)
            #expect(harness.engine.generations.isEmpty)
        }
    }

    // MARK: Checkpoint

    @Test
    func theKVCheckpointIsRefusedForASessionThatHoldsImages() async throws {
        try await withClient { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["seen"])
            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "Look", attachments: [VisionSupport.png], onEvent: { _ in }
            )
            let url = harness.base.appendingPathComponent("with-images.kv")

            let outcome = try await setup.client.saveEngineCheckpoint(sessionID: "session", to: url)

            #expect(outcome == .skippedImages)
            #expect(!VisionSupport.exists(url))
            #expect(harness.mock.calls.allSatisfy { call in
                if case .saveCheckpoint = call { false } else { true }
            })
            // The engine session itself is image-conditioned and refuses too.
            let direct = harness.base.appendingPathComponent("direct.kv")
            let engineOutcome = try await harness.engine.saveCheckpoint(sessionID: "session", to: direct, trailer: nil)
            #expect(engineOutcome == .skippedVision)
            #expect(!VisionSupport.exists(direct))
        }
    }

    @Test
    func theKVCheckpointIsRefusedWhenOnlyAToolReturnedTheImage() async throws {
        try await withClient(history: screenshotHistory()) { setup in
            let harness = setup.harness
            harness.mock.enqueueGeneration(["A window."])
            _ = try await setup.client.sendPrompt(
                sessionID: "session", prompt: "What do you see?", attachments: [], onEvent: { _ in }
            )
            let url = harness.base.appendingPathComponent("tool-image.kv")

            let outcome = try await setup.client.saveEngineCheckpoint(sessionID: "session", to: url)

            #expect(outcome == .skippedImages)
            #expect(!VisionSupport.exists(url))
        }
    }
}
