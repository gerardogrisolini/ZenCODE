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
}

// MARK: - Fixtures

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
