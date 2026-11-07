import Foundation
import Synchronization
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

    // MARK: - Tool call durations

    @Test
    func transcriptCarriesTheElapsedTimeOfEveryCompletedToolCallResult() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Timed")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
            // The backend reports no tool event: nothing was recorded.
            let unmeasured = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(unmeasured.toolDurations.isEmpty)

            let completed = durationTestToolCall("call-timed")
            let untimed = durationTestToolCall("call-untimed")
            let running = durationTestToolCall("call-running")
            let anonymous = durationTestToolCall("")
            await runtime.recordEvent(.toolCallStarted(completed), agentID: agentID)
            await runtime.recordEvent(.toolCallStarted(untimed), agentID: agentID)
            await runtime.recordEvent(.toolCallStarted(running), agentID: agentID)
            await runtime.recordEvent(.toolCallStarted(anonymous), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(completed, durationTestToolResult), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(untimed, untimedTestToolResult), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(anonymous, durationTestToolResult), agentID: agentID)

            // The history has a tool call: the read that asks for the
            // descriptors carries the durations too.
            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            // The time is exactly the one the result carries.
            #expect(transcript.toolDurations["call-timed"] == .seconds(2))
            // A result without a time, a running call, and a call without an
            // id have none.
            #expect(transcript.toolDurations["call-untimed"] == nil)
            #expect(transcript.toolDurations["call-running"] == nil)
            #expect(transcript.toolDurations[""] == nil)
            #expect(transcript.toolDurations.count == 1)

            await runtime.shutdown()
        }
    }

    @Test
    func theCompletedToolEventCarriesTheResultWhoseTimeTheTranscriptShows() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let events = TranscriptToolEventLog()
            await runtime.updateSubAgentToolEventHandler { event in events.append(event) }
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Events")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let timed = durationTestToolCall("call-timed")
            let untimed = durationTestToolCall("call-untimed")
            await runtime.recordEvent(.toolCallStarted(timed), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(timed, durationTestToolResult), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(untimed, untimedTestToolResult), agentID: agentID)

            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcript.toolDurations == ["call-timed": .seconds(2)])
            let recorded = events.snapshot.filter { $0.agentID == agentID }
            #expect(recorded.map(\.toolCall.id) == ["call-timed", "call-timed", "call-untimed"])
            guard recorded.count == 3 else { return }
            // The completion hands on the result unchanged, its time included:
            // the time the transcript shows for its call.
            guard case .started = recorded[0].lifecycle else {
                Issue.record("The first event is not a start")
                return
            }
            guard case let .completed(timedResult) = recorded[1].lifecycle,
                  case let .completed(untimedResult) = recorded[2].lifecycle else {
                Issue.record("The completions are not completions")
                return
            }
            #expect(timedResult == durationTestToolResult)
            #expect(timedResult.elapsed == transcript.toolDurations["call-timed"])
            #expect(untimedResult == untimedTestToolResult)
            #expect(untimedResult.elapsed == nil)

            await runtime.shutdown()
        }
    }

    @Test
    func aNewTurnKeepsTheRecordedDurations() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "First")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let finished = durationTestToolCall("call-finished")
            let leftOpen = durationTestToolCall("call-left-open")
            await runtime.recordEvent(.toolCallStarted(finished), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(finished, durationTestToolResult), agentID: agentID)
            await runtime.recordEvent(.toolCallStarted(leftOpen), agentID: agentID)
            let measured = try #require(
                await runtime.transcript(agentID: agentID, rootSessionID: "root")?.toolDurations["call-finished"]
            )

            try await runtime.queuePrompt("Second", for: agentID)
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
            // A late completion whose result has no time adds none.
            await runtime.recordEvent(.toolCallCompleted(leftOpen, untimedTestToolResult), agentID: agentID)

            let transcript = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcriptLabels(transcript.kinds).contains("user:Second"))
            #expect(transcript.toolDurations == ["call-finished": measured])

            await runtime.shutdown()
        }
    }

    @Test
    func theMeasuredDurationsSurviveTheEndOfTheAgent() async throws {
        try await withTranscriptTestSupportDirectory {
            let backend = TranscriptRecordingSubAgentBackend()
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Ending")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
            let call = durationTestToolCall("call-before-the-end")
            await runtime.recordEvent(.toolCallStarted(call), agentID: agentID)
            await runtime.recordEvent(.toolCallCompleted(call, durationTestToolResult), agentID: agentID)
            let measured = try #require(
                await runtime.transcript(agentID: agentID, rootSessionID: "root")?.toolDurations["call-before-the-end"]
            )

            // A failed taskless agent keeps its backend: its transcript is
            // still read, with the times.
            await runtime.recordFailure(CancellationError(), agentID: agentID)
            #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .failed)
            let failed = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(failed.toolDurations == ["call-before-the-end": measured])

            // The close prepares the record for terminal retention: the
            // durations stay in it, bounded.
            _ = try await runtime.closeAgent(arguments: ["id": .string(agentID)])
            #expect(await runtime.retainedToolCallDurations(agentID: agentID) == ["call-before-the-end": measured])

            await runtime.shutdown()
        }
    }

    @Test
    func theMeasuredDurationsKeepOnlyTheLatestCallsOfTheAgent() async throws {
        try await withTranscriptTestSupportDirectory {
            // A history without tool calls: the read that needs no descriptor
            // carries the durations too.
            let backend = ScriptedTranscriptSubAgentBackend(
                history: [AgentRuntimeMessage(role: .user, content: "Many")]
            )
            let runtime = makeDirectSubAgentRuntime(backend: backend)
            let agentID = try await createTranscriptAgent(in: runtime, rootSessionID: "root", prompt: "Many")
            await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)

            let limit = DirectSubAgentRuntime.maximumRetainedToolCallDurationsPerAgent
            #expect(limit == 512)
            func complete(_ id: String) async {
                let call = durationTestToolCall(id)
                await runtime.recordEvent(.toolCallStarted(call), agentID: agentID)
                await runtime.recordEvent(.toolCallCompleted(call, durationTestToolResult), agentID: agentID)
            }
            for index in 0...limit {
                await complete("call-\(index)")
            }
            let full = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(transcriptLabels(full.kinds) == ["user:Many"])
            // One call more than the limit: the oldest was evicted.
            #expect(full.toolDurations.count == limit)
            #expect(full.toolDurations["call-0"] == nil)
            #expect(full.toolDurations["call-1"] != nil)
            #expect(full.toolDurations["call-\(limit)"] != nil)

            // A repeated id overwrites its duration and becomes the newest, so
            // the next eviction takes the call after it.
            await complete("call-1")
            await complete("call-extra")
            let latest = try #require(await runtime.transcript(agentID: agentID, rootSessionID: "root"))
            #expect(latest.toolDurations.count == limit)
            #expect(latest.toolDurations["call-1"] != nil)
            #expect(latest.toolDurations["call-2"] == nil)
            #expect(latest.toolDurations["call-3"] != nil)
            #expect(latest.toolDurations["call-extra"] != nil)

            await runtime.shutdown()
        }
    }
}

// MARK: - Fixtures

/// A tool call with `id` for the duration tests; its tool has no row of its
/// own in the backend history.
private func durationTestToolCall(_ id: String) -> DirectAgentToolCall {
    DirectAgentToolCall(id: id, name: "local.exec", argumentsObject: [:], argumentsJSON: "{}")
}

/// A result with the time the tool executor measured for it.
private let durationTestToolResult = DirectAgentToolResult(output: "ok", summary: "ok", elapsed: .seconds(2))

/// A result the tool executor did not produce: it has no time.
private let untimedTestToolResult = DirectAgentToolResult(output: "ok", summary: "ok")

/// The delegated tool events a runtime handed its handler, in order.
private final class TranscriptToolEventLog: Sendable {
    private let events = Mutex<[DirectSubAgentToolEvent]>([])

    var snapshot: [DirectSubAgentToolEvent] {
        events.withLock { $0 }
    }

    func append(_ event: DirectSubAgentToolEvent) {
        events.withLock { $0.append(event) }
    }
}

private extension DirectSubAgentRuntime {
    /// The durations kept in the record of `agentID`, by tool call id; `nil`
    /// without such a record.
    func retainedToolCallDurations(agentID: String) -> [String: Duration]? {
        agents[agentID]?.toolCallDurations.byCallID
    }
}

/// A sub-agent backend whose session history is the given one, whatever the
/// prompts, and whose known tool descriptors are the given ones. It records the
/// sessions it creates and the session of every known-descriptor request; its
/// active descriptors, which a real backend can discover, are empty, so a
/// transcript that asked for them would show no descriptor.
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

    func activeToolDescriptors(sessionID _: String?) async -> [DirectToolDescriptor] {
        []
    }

    func knownToolDescriptors(sessionID: String?) async -> [DirectToolDescriptor] {
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
