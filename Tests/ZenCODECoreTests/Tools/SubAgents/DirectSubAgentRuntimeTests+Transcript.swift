import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    // MARK: - Sub-agent transcripts

    @Test
    func liveAgentTranscriptIsTheBackendHistory() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Investigate")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcript.agentID == agentID)
            #expect(transcriptLabels(transcript.kinds) == oneRoundLabels(prompt: "Investigate") + [
                "text:Finished: Investigate",
            ])
            #expect(transcript.kinds.first == .userPrompt(text: "Investigate", attachments: [], origin: .unknown))
            #expect(await backend.shutdownCount() == 0)

            await runtime.shutdown()
        }
    }

    @Test
    func transcriptFollowsARunningTurnAndIsNilOnceTheCloseShutsTheBackendDown() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend(outcome: .blockUntilCancelled)
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Long work")
            await backend.waitUntilBlocked()

            // The turn is still running: its tool round is already in the
            // backend history.
            let live = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcriptLabels(live.kinds) == oneRoundLabels(prompt: "Long work"))

            // The close shuts the backend down: the runtime keeps no copy.
            _ = try await runtime.closeAgent(arguments: ["id": .string(agentID)])
            #expect(await backend.shutdownCount() >= 1)
            #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .closed)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") == nil)

            // The cancelled turn shuts the backend down a second time: still
            // nothing to read.
            await backend.waitUntilShutdownCount(2)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") == nil)

            await runtime.shutdown()
        }
    }

    @Test
    func closedAgentHasNoTranscript() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Work")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") != nil)

            _ = try await runtime.closeAgent(arguments: ["id": .string(agentID)])

            #expect(await backend.shutdownCount() == 1)
            // The terminal record is still there, the history is not.
            #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .closed)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") == nil)

            await runtime.shutdown()
        }
    }

    @Test
    func cancelledAgentHasNoTranscript() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Work")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") != nil)

            await runtime.recordCancellation(agentID: agentID)

            #expect(await backend.shutdownCount() == 1)
            #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .closed)
            #expect(await runtime.transcript(agentID: agentID, rootSessionID: "root") == nil)

            await runtime.shutdown()
        }
    }

    @Test
    func transcriptIsNilForAnUnknownAgentOrAnAgentOfAnotherRootSession() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let firstID = try await createTranscriptAgent(in: runtime, rootSessionID: "root-a", prompt: "A")
            let secondID = try await createTranscriptAgent(in: runtime, rootSessionID: "root-b", prompt: "B")
            await runtime.waitForDirectSubAgentTestWorkLoops()

            #expect(await runtime.transcript(agentID: firstID, rootSessionID: "root-a") != nil)
            #expect(await runtime.transcript(agentID: secondID, rootSessionID: "root-b") != nil)
            #expect(await runtime.transcript(agentID: firstID, rootSessionID: "root-b") == nil)
            #expect(await runtime.transcript(agentID: secondID, rootSessionID: "root-a") == nil)
            #expect(await runtime.transcript(agentID: "agent_missing", rootSessionID: "root-a") == nil)

            await runtime.shutdown()
        }
    }

    @Test
    func transcriptToolCallsCarryThePresentationOfTheSubAgentDescriptors() async throws {
        try await withTranscriptTestSupportDirectory {
            let presentation = ToolPresentationDefinition(
                title: "Read file",
                action: "Read",
                kind: .read,
                target: .argument(["path"], format: .text)
            )
            let backend = ScriptedTranscriptSubAgentBackend(
                history: [
                    AgentRuntimeMessage(role: .user, content: "Inspect"),
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Reading.",
                        toolCalls: [
                            AgentRuntimeToolCall(
                                id: "call-read",
                                name: "local.readFile",
                                argumentsJSON: #"{"path":"round-0.txt"}"#
                            ),
                            AgentRuntimeToolCall(
                                id: "call-unlisted",
                                name: "custom.unlisted",
                                argumentsJSON: #"{"value":"x"}"#
                            ),
                        ]
                    ),
                    AgentRuntimeMessage(
                        role: .tool,
                        content: "contents of round 0",
                        toolCallID: "call-read",
                        toolName: "local.readFile"
                    ),
                    AgentRuntimeMessage(
                        role: .tool,
                        content: "unlisted output",
                        toolCallID: "call-unlisted",
                        toolName: "custom.unlisted"
                    ),
                ],
                descriptors: [
                    DirectToolDescriptor(
                        name: "local.readFile",
                        description: "Reads a file.",
                        inputSchema: #"{"type":"object"}"#,
                        title: "Read file",
                        presentation: presentation
                    ),
                    // A repeated name: the first descriptor wins.
                    DirectToolDescriptor(
                        name: "local.readFile",
                        description: "Shadowed.",
                        inputSchema: #"{"type":"object"}"#,
                        title: "Shadowed read"
                    ),
                ]
            )
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Inspect")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let requestsBefore = await backend.descriptorRequestSessionIDs().count
            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcriptLabels(transcript.kinds) == [
                "user:Inspect",
                "text:Reading.",
                "start:local.readFile",
                "start:custom.unlisted",
                "done:local.readFile:contents of round 0",
                "done:custom.unlisted:unlisted output",
            ])
            // The descriptors are the sub-agent's own: requested for its
            // session.
            let requests = await backend.descriptorRequestSessionIDs()
            let sessionID = try #require(await backend.createdSessionIDs().first)
            #expect(requests.count == requestsBefore + 1)
            #expect(requests.last == sessionID)

            let calls = transcriptToolCalls(transcript.kinds)
            let readCalls = calls.filter { $0.name == "local.readFile" }
            #expect(readCalls.count == 2)
            for call in readCalls {
                #expect(call.id == "call-read")
                #expect(call.argumentsObject["path"] as? String == "round-0.txt")
                #expect(call.argumentsJSON == #"{"path":"round-0.txt"}"#)
                #expect(call.descriptorTitle == "Read file")
                #expect(call.presentation == presentation)
                #expect(ToolCallPresentation.displayToolTarget(for: call) == "round-0.txt")
            }
            // A tool without a descriptor is left as rebuilt.
            let unlistedCalls = calls.filter { $0.name == "custom.unlisted" }
            #expect(unlistedCalls.count == 2)
            for call in unlistedCalls {
                #expect(call.id == "call-unlisted")
                #expect(call.argumentsJSON == #"{"value":"x"}"#)
                #expect(call.descriptorTitle == nil)
                #expect(call.presentation == nil)
            }

            await runtime.shutdown()
        }
    }

    @Test
    func transcriptThoughtComesFromTheThinkingBlocksWhenTheMessageHasNoReasoning() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = ScriptedTranscriptSubAgentBackend(
                history: [
                    AgentRuntimeMessage(role: .user, content: "Think"),
                    // Only the blocks keep the reasoning; the redacted block
                    // has no text, and a block counts without a signature.
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Answer one.",
                        thinkingBlocksJSON: #"[{"type":"thinking","thinking":"First idea.","signature":"sig-1"},"#
                            + #"{"type":"redacted_thinking","data":"opaque"},"#
                            + #"{"type":"thinking","thinking":"Second idea."}]"#
                    ),
                    // The message's own reasoning wins over its blocks.
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Answer two.",
                        reasoningContent: "Kept reasoning.",
                        thinkingBlocksJSON: #"[{"type":"thinking","thinking":"Ignored.","signature":"sig-2"}]"#
                    ),
                    // Only redacted blocks: no thought.
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Answer three.",
                        thinkingBlocksJSON: #"[{"type":"redacted_thinking","data":"opaque"}]"#
                    ),
                ]
            )
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Think")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let requestsBefore = await backend.descriptorRequestSessionIDs().count
            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcriptLabels(transcript.kinds) == [
                "user:Think",
                "thought:First idea.\n\nSecond idea.",
                "text:Answer one.",
                "thought:Kept reasoning.",
                "text:Answer two.",
                "text:Answer three.",
            ])
            // Without a tool call the descriptors are not requested.
            #expect(await backend.descriptorRequestSessionIDs().count == requestsBefore)

            await runtime.shutdown()
        }
    }
}

// MARK: - Fixtures

/// A sub-agent backend whose session history is the given one, whatever the
/// prompts, and whose tool descriptors are the given ones. It records the
/// sessions it creates and the session of every descriptor request.
/// `shutdown()` drops every session, as a real backend that was shut down.
private actor ScriptedTranscriptSubAgentBackend: AgentRuntimeBackend {
    private let history: [AgentRuntimeMessage]
    private let descriptors: [DirectToolDescriptor]
    private var sessionIDs: [String] = []
    private var descriptorRequests: [String?] = []

    init(history: [AgentRuntimeMessage], descriptors: [DirectToolDescriptor] = []) {
        self.history = history
        self.descriptors = descriptors
    }

    // MARK: Test probes

    func createdSessionIDs() -> [String] {
        sessionIDs
    }

    func descriptorRequestSessionIDs() -> [String?] {
        descriptorRequests
    }

    // MARK: AgentRuntimeBackend

    func createSession(
        id: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        guard !sessionIDs.contains(id) else { return }
        sessionIDs.append(id)
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessionIDs.removeAll { $0 == id }
    }

    func shutdown() {
        sessionIDs.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: nil)
    }

    func activeToolDescriptors(sessionID: String?) async -> [DirectToolDescriptor] {
        descriptorRequests.append(sessionID)
        return descriptors
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(
            text: "Finished: \(prompt)",
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard sessionIDs.contains(id) else { return nil }
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: "/tmp",
            systemPrompt: nil,
            cacheKey: nil,
            history: history,
            allowedToolNames: nil,
            thinkingSelection: nil,
            preserveThinking: false
        )
    }
}

/// The tool calls of the started and completed entries of `kinds`, in order.
private func transcriptToolCalls(_ kinds: [ChatTurnEntry.Kind]) -> [DirectAgentToolCall] {
    kinds.compactMap { kind in
        switch kind {
        case let .toolCallStarted(call), let .toolCallCompleted(call, _):
            call
        default:
            nil
        }
    }
}

/// Runs `body` with a throwaway support directory: a delegated turn whose
/// backend reports a session snapshot resolves automatic recall from the
/// support directory, which must never be the real application state.
func withTranscriptTestSupportDirectory(
    _ body: () async throws -> Void
) async throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
        "zencode-sub-agent-transcript-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try await AppStorageDirectory.withSupportDirectoryURL(support) {
        try await body()
    }
}

/// Creates one Developer agent that starts on `prompt` and returns its ID.
private func createTranscriptAgent(
    in runtime: DirectSubAgentRuntime,
    rootSessionID: String,
    prompt: String
) async throws -> String {
    let arguments: [String: JSONValue] = [
        "name": .string("transcript-\(prompt.lowercased().replacingOccurrences(of: " ", with: "-"))"),
        "profile": .string("Developer"),
        "prompt": .string(prompt),
    ]
    let before = Set(await runtime.snapshots().map(\.id))
    _ = try await runtime.createAgents(
        arguments: arguments,
        workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-transcript-tests", isDirectory: true),
        parentAllowedToolNames: nil,
        rootSessionID: rootSessionID
    )
    let created = await runtime.snapshots().map(\.id).filter { !before.contains($0) }
    return try #require(created.first)
}

/// What one turn of ``TranscriptRecordingSubAgentBackend`` with a single tool
/// round records before its final text.
func oneRoundLabels(prompt: String) -> [String] {
    [
        "user:\(prompt)",
        "thought:Round 0 needs the file.",
        "text:Reading round 0.",
        "start:local.readFile",
        "done:local.readFile:contents of round 0",
    ]
}

/// A compact projection of transcript kinds for comparisons.
func transcriptLabels(_ kinds: [ChatTurnEntry.Kind]) -> [String] {
    kinds.map { kind in
        switch kind {
        case let .userPrompt(text, _, _):
            "user:\(text)"
        case let .thought(text):
            "thought:\(text)"
        case let .assistantText(text):
            "text:\(text)"
        case let .toolCallStarted(call):
            "start:\(call.name)"
        case let .toolCallCompleted(call, result):
            "done:\(call.name):\(result.output.prefix(40))"
        default:
            "other"
        }
    }
}
