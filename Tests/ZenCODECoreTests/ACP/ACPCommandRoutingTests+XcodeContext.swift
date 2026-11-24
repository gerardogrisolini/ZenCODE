//
//  ACPCommandRoutingTests+XcodeContext.swift
//  ZenCODE
//
//  Commands and agent mentions typed in Xcode: the context blocks Xcode sends
//  before the operator's text do not hide them, and a turn they start still
//  passes that context to the model.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension ACPCommandRoutingTests {
    /// The context block current Xcode releases send before the operator's
    /// text.
    private static let xcodeProjectStructure = """
    Project structure (these are Xcode workspace-relative paths and do not correspond to filesystem \
    paths. Use XcodeRead, XcodeWrite, XcodeGrep, and XcodeGlob to interact with these files):
    App/App.swift

    Package dependencies: swift-collections

    The user has no file currently open.

    """

    private func sendPrompt(
        _ blocks: [[String: any Sendable]],
        id: Int,
        to bridge: ZenCODEACPBridge,
        sessionID: String
    ) async {
        await bridge.handleMessage([
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": ["sessionId": sessionID, "prompt": blocks] as [String: Any],
        ])
    }

    /// `/tasks`, with or without an agent mention, is answered at once after
    /// Xcode's context and never reaches the model.
    @Test
    func commandsAnsweredAtOnceAreRoutedAfterTheXcodeContext() async throws {
        let fixture = try await makeFixture(sessionID: "acp-xcode-tasks-\(UUID().uuidString)")
        let structure: [String: any Sendable] = ["type": "text", "text": Self.xcodeProjectStructure]

        for (index, line) in ["/tasks", "@Developer /tasks"].enumerated() {
            await sendPrompt(
                [structure, ["type": "text", "text": line]],
                id: index + 1, to: fixture.bridge, sessionID: fixture.sessionID
            )
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last == "No task graph for this session.")
            // The echo drops the agent mention, as it does in any client.
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk").last == "/tasks")
            #expect(fixture.wire.stopReason(for: index + 1) == "end_turn")
        }
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// `/goal` after Xcode's context starts the workflow on the operator's
    /// goal alone, and the turn it starts still gives the model the context.
    @Test
    func aGoalTypedInXcodeStartsTheWorkflowAndKeepsTheContextForTheModel() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-xcode-goal-\(UUID().uuidString)", allowedToolNames: ["local.read"]
        )
        await sendPrompt(
            [
                ["type": "text", "text": "<system-reminder>Prefer the Xcode tools.</system-reminder>"],
                ["type": "text", "text": Self.xcodeProjectStructure],
                ["type": "text", "text": "/goal Preserve direct objective"],
            ],
            id: 1, to: fixture.bridge, sessionID: fixture.sessionID
        )

        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.workflow?.originalGoal == "Preserve direct objective")
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk") == ["/goal Preserve direct objective"])
        let prompt = try #require(await fixture.backend.recordedPrompts().first)
        #expect(prompt.contains("<system-reminder>Prefer the Xcode tools.</system-reminder>\n\nProject structure ("))
        let context = try #require(prompt.range(of: "The user has no file currently open."))
        let goal = try #require(prompt.range(of: "Preserve direct objective"))
        #expect(context.upperBound <= goal.lowerBound)
    }

    /// Without Xcode's context a command keeps the whole prompt as before:
    /// text that is not Xcode's context before it makes it an ordinary prompt.
    @Test
    func aCommandAfterOtherContextStaysAnOrdinaryPrompt() async throws {
        let fixture = try await makeFixture(sessionID: "acp-xcode-other-\(UUID().uuidString)")
        await sendPrompt(
            [["type": "text", "text": "arbitrary context"], ["type": "text", "text": "/tasks"]],
            id: 1, to: fixture.bridge, sessionID: fixture.sessionID
        )
        let prompts = await fixture.backend.recordedPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("arbitrary context\n\n/tasks") == true)
    }

    /// A leading mention of a known agent after Xcode's context switches the
    /// session to that agent, as it does in any client; the echo drops the
    /// mention, and the model gets the context before the operator's text.
    @Test
    func anAgentMentionTypedInXcodeSwitchesTheAgentAndKeepsTheContext() async throws {
        let fixture = try await makeFixture(sessionID: "acp-xcode-mention-\(UUID().uuidString)")
        let structure: [String: any Sendable] = ["type": "text", "text": Self.xcodeProjectStructure]
        await sendPrompt(
            [structure, ["type": "text", "text": "@Planner analyze the parser"]],
            id: 1, to: fixture.bridge, sessionID: fixture.sessionID
        )

        let configuration = try #require(await fixture.bridge.sessionConfigurationsForTesting().first)
        #expect(configuration.agentRole == .planner)
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk") == ["analyze the parser"])
        #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        let prompt = try #require(await fixture.backend.recordedPrompts().last)
        let context = try #require(prompt.range(of: "The user has no file currently open."))
        let request = try #require(prompt.range(of: "analyze the parser"))
        #expect(context.upperBound <= request.lowerBound)
        #expect(!prompt.contains("@Planner analyze"))
    }

    /// A mention of no known agent after Xcode's context is ordinary text: the
    /// current agent receives the whole prompt.
    @Test
    func anUnknownMentionTypedInXcodeStaysAnOrdinaryPrompt() async throws {
        let fixture = try await makeFixture(sessionID: "acp-xcode-unknown-\(UUID().uuidString)")
        let agentBefore = await fixture.bridge.sessionConfigurationsForTesting().first?.agentID
        let structure: [String: any Sendable] = ["type": "text", "text": Self.xcodeProjectStructure]
        await sendPrompt(
            [structure, ["type": "text", "text": "@Nobody say hello"]],
            id: 1, to: fixture.bridge, sessionID: fixture.sessionID
        )

        #expect(await fixture.bridge.sessionConfigurationsForTesting().first?.agentID == agentBefore)
        let prompt = try #require(await fixture.backend.recordedPrompts().last)
        #expect(prompt.contains("Project structure ("))
        #expect(prompt.contains("@Nobody say hello"))
    }

    /// Only a routed command is taken from its own block: other slash text
    /// and plain text after Xcode's context keep the whole prompt.
    @Test
    func onlyRoutedCommandsAreTakenFromTheirOwnBlock() {
        let structure: [String: Any] = ["type": "text", "text": Self.xcodeProjectStructure]
        for line in ["/goal ship it", "/plan status", "/review", "/tasks", "/telegram on", "/changes", "/undo",
                     "@Developer /goal ship it"] {
            let source = ZenCODEACPBridge.routedCommandSource(from: [structure, ["type": "text", "text": line]])
            #expect(source?.text == line, "\(line)")
            #expect(source?.followsXcodeContext == true, "\(line)")
        }
        for line in ["/unknown", "What does /goal do?", "@Developer explain"] {
            #expect(ZenCODEACPBridge.routedCommandSource(from: [structure, ["type": "text", "text": line]]) == nil,
                    "\(line)")
        }
        // A coordinator command in a prompt without Xcode's context keeps the
        // whole prompt; a workspace command still uses its own block.
        let resource: [String: Any] = ["type": "resource", "resource": ["text": "notes"]]
        #expect(ZenCODEACPBridge.routedCommandSource(from: [["type": "text", "text": "/goal x"], resource]) == nil)
        #expect(ZenCODEACPBridge.routedCommandSource(from: [["type": "text", "text": "/undo"], resource])?.text
            == "/undo")
    }
}
