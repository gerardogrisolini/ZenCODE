//
//  TerminalChatLiveArtifactTests+Delegated.swift
//  ZenCODE
//
//  Tests of the live file artifacts of the terminal chat for root and
//  delegated edits, with the scripted backends they run against.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TerminalChatLiveArtifactTests {
    @Test
    nonisolated func rootAndDelegatedArtifactsArePresentedOnceButNotWrittenInTheChat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.live-artifacts") { @ChatSessionActor in
                let renderer = makeRenderer()
                let backend = LiveArtifactBackend()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(directory, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                await backend.setProbe {
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    for source in ["root source", "delegated source", "next source"] {
                        #expect(!output.contains(source))
                    }
                    #expect(!output.contains("🪬 Artifacts"))
                    // The fake model has not returned its response yet.
                    #expect(!output.contains("generation ended"))
                    // Every completion is presented once, attributed to its agent.
                    let presented = await recorder.markdown
                    for row in ["1 │ +root source", "1 │ +delegated source", "1 │ +next source"] {
                        #expect(presented.components(separatedBy: row).count - 1 == 1)
                    }
                    #expect(await recorder.liveAgentIDs == [nil, "worker", "worker"])
                    #expect(await recorder.sealedTurns.isEmpty)
                    let history = await terminal.chatSession.fileArtifactHistory
                    #expect(await history.snapshot().isEmpty)
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(success.response.text == "generation ended")
                #expect(await backend.didProbeBeforeReturning())
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for source in ["root source", "delegated source", "next source"] {
                    #expect(!output.contains(source))
                }
                #expect(!output.contains("│ +"))
                #expect(recorder.presentations.count == 3)
                #expect(terminal.chatSession.activeFileArtifactTurn == nil)
                await runner.shutdown()
            }.value
        }
    }

    @Test(arguments: [false, true], [false, true])
    nonisolated func opaqueArtifactsReachTheSnapshotAtEachCompletionAndTheSummaryFollowsTheAnswer(
        delegated: Bool, isTerminal: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        for arguments in [["init"], ["add", "."], ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"]] {
            let process = Process()
            process.executableURL = GitExecutableResolver.executableURL()
            process.arguments = ["-C", workspace.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.artifact-ordering") { @ChatSessionActor in
                let renderer = makeRenderer(isTerminal: isTerminal)
                let backend = CompletionArtifactBackend(workspace: workspace, delegated: delegated)
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(workspace, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                await backend.setProbe { stage in
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    #expect(output.contains("Preparing edits"))
                    #expect(!output.contains("+stage"))
                    #expect(!output.contains("Final answer"))
                    #expect(!output.contains("Summary"))
                    // The completion is presented, and the panel's snapshot
                    // lists the turn in progress with its net changes so far.
                    #expect(await recorder.markdown.components(separatedBy: "1 │ +stage \(stage)").count - 1 == 1)
                    let snapshot = await terminal.chatSession.fileArtifactSnapshot()
                    #expect(snapshot.activeTurnNumber == 1)
                    #expect(snapshot.turns.map(\.number) == [1])
                    #expect(snapshot.turns.first?.artifacts.map(\.displayPath) == ["file.txt"])
                    let listed = TerminalChat.renderFileArtifacts(snapshot.turns, includeHistoryHeadings: false)
                    #expect(listed.contains("1 │ -initial"))
                    #expect(listed.contains("1 │ +stage \(stage)"))
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                let beforeFinish = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                #expect(!beforeFinish.contains("late fallback"))
                #expect(!beforeFinish.contains("Final answer"))
                // The edit after the last completion is presented once, sealed.
                #expect(recorder.liveAgentIDs == (delegated ? ["worker", "worker"] : [nil, nil]))
                #expect(recorder.sealedTurns.count == 1)
                #expect(TerminalChat.renderFileArtifacts(recorder.sealedTurns, includeHistoryHeadings: false)
                    .contains("1 │ +late fallback"))
                await terminal.finishPromptResult(.success(success))
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for text in ["Preparing edits", "Final answer"] {
                    #expect(output.components(separatedBy: text).count - 1 == 1)
                }
                for text in ["+stage 1", "+stage 2", "late fallback", "│ +", "🪬 Artifacts"] {
                    #expect(!output.contains(text))
                }
                let answer = try #require(output.range(of: "Final answer"))
                let summary = try #require(output.range(of: "Summary"))
                #expect(answer.lowerBound < summary.lowerBound)
                let tail = output[answer.upperBound..<summary.lowerBound]
                #expect(!tail.contains("file.txt"))
                #expect(success.fileChangeSummary?.entries.first?.beforeDataBase64 == Data("initial\n".utf8).base64EncodedString())
                #expect(await terminal.chatSession.fileArtifactHistory.snapshot().count == 1)
                // Finished, the turn is listed once, with its final evidence.
                let snapshot = await terminal.chatSession.fileArtifactSnapshot()
                #expect(snapshot.activeTurnNumber == nil)
                #expect(snapshot.turns.map(\.number) == [1])
                #expect(TerminalChat.renderFileArtifacts(snapshot.turns, includeHistoryHeadings: false)
                    .contains("1 │ +late fallback"))
                await runner.shutdown()
            }.value
        }
    }

    /// A delegated mutation no longer writes an artifact in the chat: what
    /// follows the delegated completion is the sub-agent overview alone,
    /// published again with the completed tool row of the agent.
    @Test
    nonisolated func aDelegatedMutationRepublishesTheSubAgentOverviewWithItsToolRow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.delegated-overview") { @ChatSessionActor in
                let renderer = makeRenderer(isTerminal: true)
                let backend = DelegatedOverviewBackend()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(directory, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                let probes = DelegatedOverviewProbes()
                await backend.setProbe { stage in
                    let events = await renderer.capturedWriteEvents()
                    await probes.record(stage, eventCount: events.count)
                    let output = TerminalANSIText.stripANSI(events.map(\.text).joined())
                    switch stage {
                    case "started":
                        let overview = output.components(separatedBy: "👥 Sub-Agents:").last ?? ""
                        #expect(overview.contains("● worker"))
                        #expect(overview.contains("local.write ⏳"))
                    default:
                        let started = await probes.eventCount("started")
                        let completion = TerminalANSIText.stripANSI(
                            events.dropFirst(started).map(\.text).joined()
                        )
                        // Only the overview follows: one section, its tool row completed.
                        #expect(completion.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("👥 Sub-Agents:"))
                        #expect(completion.components(separatedBy: "👥 Sub-Agents:").count - 1 == 1)
                        #expect(completion.contains("● worker"))
                        #expect(completion.contains("local.write ✅"))
                        #expect(!completion.contains("Delegated.swift"))
                        #expect(!completion.contains("delegated source"))
                        #expect(!completion.contains("│ +"))
                        let tool = await renderer.subAgentToolPresentationSnapshot().presentationsByAgentID["worker"]
                        if case .completed? = tool?.lifecycle {} else {
                            Issue.record("The delegated tool row did not complete")
                        }
                        #expect(await recorder.liveAgentIDs == ["worker"])
                    }
                }
                _ = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "delegate", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(await probes.stages == ["started", "completed"])
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                #expect(!output.contains("delegated source"))
                #expect(!output.contains("│ +"))
                await runner.shutdown()
            }.value
        }
    }
}

private actor LiveArtifactBackend: AgentRuntimeBackend {
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable () async -> Void)?
    private var didProbe = false

    func setProbe(_ probe: @escaping @Sendable () async -> Void) { self.probe = probe }
    func didProbeBeforeReturning() -> Bool { didProbe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        let call = DirectAgentToolCall(id: "shared-call", name: "local.write", argumentsObject: ["path": "Live.swift"], argumentsJSON: "{}")
        let root = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Live.swift", oldText: nil, newText: "root source\n")
        ])
        await onEvent(.thought("thinking before root"))
        await onEvent(.toolCallStarted(call))
        await onEvent(.toolCallCompleted(call, root))
        await onEvent(.toolCallCompleted(call, root))
        await onEvent(.content("assistant still active"))
        let delegated = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Live.swift", oldText: "root source\n", newText: "delegated source\n")
        ])
        let event = DirectSubAgentToolEvent(
            agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(delegated),
            rootSessionID: sessionID
        )
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
        await handler?(event)
        await handler?(event)
        let next = DirectAgentToolCall(id: "next-call", name: "local.write", argumentsObject: ["path": "Live.swift"], argumentsJSON: "{}")
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: next, lifecycle: .completed(
            DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
                .init(path: "Live.swift", oldText: "delegated source\n", newText: "next source\n")
            ])
        ), rootSessionID: sessionID))
        await probe?()
        didProbe = true
        await onEvent(.content("generation ended"))
        return DirectAgentResponse(text: "generation ended", stopReason: "end_turn", modelID: "test-model")
    }
}

private actor CompletionArtifactBackend: AgentRuntimeBackend {
    let workspace: URL
    let delegated: Bool
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable (Int) async -> Void)?

    init(workspace: URL, delegated: Bool) {
        self.workspace = workspace
        self.delegated = delegated
    }

    func setProbe(_ probe: @escaping @Sendable (Int) async -> Void) { self.probe = probe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        await onEvent(.content("Preparing "))
        await onEvent(.content("edits\n"))
        let parent = DirectAgentToolCall(id: "parent", name: "agent.wait", argumentsObject: [:], argumentsJSON: "{}")
        if delegated { await onEvent(.toolCallStarted(parent)) }
        for stage in 1...2 {
            let call = DirectAgentToolCall(id: "shell-\(stage)", name: "local.exec", argumentsObject: ["command": "edit"], argumentsJSON: "{}")
            if delegated {
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
            } else {
                await onEvent(.toolCallStarted(call))
            }
            try Data("stage \(stage)\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
            // A failed command may also have written files before exiting.
            let result = DirectAgentToolResult(output: "done", summary: "done", status: stage == 1 ? .completed : .failed)
            if delegated {
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result), rootSessionID: sessionID))
            } else {
                await onEvent(.toolCallCompleted(call, result))
            }
            await probe?(stage)
        }
        if delegated { await onEvent(.toolCallCompleted(parent, .init(output: "done", summary: "done"))) }
        await onEvent(.content("**Final "))
        await onEvent(.content("answer**\n"))
        // Exercise the safety-net reconciliation after the final model delta.
        try Data("late fallback\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        return DirectAgentResponse(text: "Preparing edits\n**Final answer**\n", stopReason: "end_turn", modelID: "test-model")
    }
}

/// The renderer's write count at each probe of ``DelegatedOverviewBackend``.
private actor DelegatedOverviewProbes {
    private(set) var stages: [String] = []
    private var eventCounts: [String: Int] = [:]

    func record(_ stage: String, eventCount: Int) {
        stages.append(stage)
        eventCounts[stage] = eventCount
    }

    func eventCount(_ stage: String) -> Int {
        eventCounts[stage] ?? 0
    }
}

/// A coordinator waiting for one sub-agent in progress, which writes a file:
/// the delegated call is probed once started and once completed.
private actor DelegatedOverviewBackend: AgentRuntimeBackend {
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable (String) async -> Void)?

    func setProbe(_ probe: @escaping @Sendable (String) async -> Void) { self.probe = probe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func subAgentSnapshots() -> [DirectSubAgentRuntime.AgentSnapshot] {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return [DirectSubAgentRuntime.AgentSnapshot(
            id: "worker",
            name: "worker",
            profileName: nil,
            status: .running,
            pending: true,
            configuredModelID: nil,
            modelID: nil,
            currentActivity: nil,
            currentActivityKind: nil,
            currentToolName: "local.write",
            currentToolIsRunning: true,
            latestMetrics: nil,
            latestEventAt: date,
            latestOutput: nil,
            executionRevision: 1,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )]
    }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        let wait = DirectAgentToolCall(id: "wait", name: "agent.wait", argumentsObject: [:], argumentsJSON: "{}")
        await onEvent(.toolCallStarted(wait))
        let call = DirectAgentToolCall(id: "delegated-write", name: "local.write", argumentsObject: ["path": "Delegated.swift"], argumentsJSON: "{}")
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
        await probe?("started")
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Delegated.swift", oldText: nil, newText: "delegated source\n")
        ])
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result), rootSessionID: sessionID))
        await probe?("completed")
        await onEvent(.toolCallCompleted(wait, .init(output: "done", summary: "done")))
        await onEvent(.content("delegation ended"))
        return DirectAgentResponse(text: "delegation ended", stopReason: "end_turn", modelID: "test-model")
    }
}
