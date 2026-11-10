import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// `agent.wait` and the `awaitReply` wait are woken by the event they wait
/// for, not by their polling interval: with a long interval both still
/// return well before their next poll.
@Suite(.timeLimit(.minutes(1)))
struct DirectSubAgentRuntimeWakeTests {
    @Test
    func agentWaitReturnsWhenAnAgentIsClosed() async throws {
        await Task.yield()
        let (runtime, agentID) = try await Self.runningAgent()
        let waiting = Task {
            await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(30), "pollIntervalSeconds": .number(5)])
        }
        await Self.waitUntilSuspended(runtime)
        let started = ContinuousClock.now
        #expect(await runtime.closeAgent(id: agentID))
        let output = await waiting.value
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(!output.hasPrefix("Timed out waiting for delegated sub-agents."))
        await runtime.shutdown()
    }

    @Test
    func awaitReplyReturnsWhenTheReplyArrives() async throws {
        await Task.yield()
        let (runtime, agentID) = try await Self.runningAgent()
        let waiting = Task {
            await runtime.awaitSharedChatReply(
                senderID: agentID, roomID: "root", timeoutSeconds: 120, pollInterval: .seconds(60)
            )
        }
        await Self.waitUntilSuspended(runtime)
        let started = ContinuousClock.now
        let reply = DirectAgentToolCall(
            id: "reply", name: "agent.message",
            argumentsObject: ["id": agentID, "message": "Use the v2 API"], argumentsJSON: "{}"
        )
        _ = try await runtime.execute(
            rootSessionID: "root", toolCall: reply, workingDirectory: Self.workingDirectory, allowedToolNames: nil
        )
        let output = await waiting.value
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(output.hasPrefix("[Live chat reply received while you were waiting]\n"))
        #expect(output.contains("Use the v2 API"))
        await runtime.shutdown()
    }

    private static let workingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sub-agent-wake-\(UUID().uuidString)")

    /// One delegated agent whose turn stays blocked, so it keeps running.
    private static func runningAgent() async throws -> (DirectSubAgentRuntime, String) {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        _ = try await runtime.createAgents(
            arguments: ["name": .string("wake-worker"), "profile": .string("Developer"), "prompt": .string("Work")],
            workingDirectory: workingDirectory, parentAllowedToolNames: nil, rootSessionID: "root"
        )
        await backend.waitUntilSentPromptCount(1)
        return (runtime, try #require(await runtime.snapshots().first?.id))
    }

    /// Polls with a deadline, so a regression fails instead of hanging.
    private static func waitUntilSuspended(_ runtime: DirectSubAgentRuntime) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await runtime.suspendedWakeWaiterCount < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
