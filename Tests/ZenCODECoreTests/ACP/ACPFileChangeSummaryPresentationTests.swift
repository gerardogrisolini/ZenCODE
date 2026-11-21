//
//  ACPFileChangeSummaryPresentationTests.swift
//  ZenCODE
//
//  The Summary of the files a prompt turn changed on the ACP wire: the text,
//  the place it takes among the updates of the turn (the last text section,
//  after the final plan and before the reply of the prompt), and the exits of
//  the turn that present it (success, error, a cancellation that still holds
//  the prompt) or fence it (`session/cancel`).
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Records every JSON-RPC message the bridge writes, as the ordered trace a
/// client observes.
private final class SummaryWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    /// What reached the client, in order: `message:<text>` for an
    /// `agent_message_chunk`, the update kind of every other `session/update`,
    /// and `result:<id>:<stopReason>` or `error:<id>` for a reply.
    func timeline() -> [String] {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue else { return nil }
                if let update = object["params"]?.objectValue?["update"]?.objectValue,
                   let kind = update["sessionUpdate"]?.stringValue {
                    guard kind == "agent_message_chunk" else { return kind }
                    return "message:" + (update["content"]?.objectValue?["text"]?.stringValue ?? "")
                }
                guard object["method"] == nil, let id = object["id"]?.numberValue else { return nil }
                if let stopReason = object["result"]?.objectValue?["stopReason"]?.stringValue {
                    return "result:\(Int(id)):\(stopReason)"
                }
                return object["error"] == nil ? nil : "error:\(Int(id))"
            }
        }
    }

    /// The text of every `agent_message_chunk`, in order.
    func messageTexts() -> [String] {
        timeline().compactMap { $0.hasPrefix("message:") ? String($0.dropFirst("message:".count)) : nil }
    }

    /// The status of every entry of every `plan` sent, one array per update.
    func planStatuses() -> [[String]] {
        storage.withLock { values in
            values.compactMap { value -> [String]? in
                guard let update = value.objectValue?["params"]?.objectValue?["update"]?.objectValue,
                      update["sessionUpdate"] == .string("plan") else {
                    return nil
                }
                return (update["entries"]?.arrayValue ?? []).map {
                    $0.objectValue?["status"]?.stringValue ?? "<missing status>"
                }
            }
        }
    }
}

private struct SummaryBackendFailure: LocalizedError {
    var errorDescription: String? { "the backend failed the turn" }
}

/// A backend whose prompts have the form `<ending>:<file>`: it writes `<file>`
/// in the workspace through a tool call, as an agent does, and ends the turn as
/// `<ending>` says. A prompt without a file changes nothing.
///
/// - `success`: answers `All done.`
/// - `graph`: like `success`, with a task that moves to completed meanwhile
/// - `fail`: throws an error
/// - `cancel`: throws a `CancellationError`, as a provider that gave up does,
///   without any `session/cancel`
/// - `park`: parks until the turn is cancelled
private actor SummaryBackend: AgentRuntimeBackend {
    private var workspaces: [String: String] = [:]
    private var orchestrator: SessionTaskOrchestrator?
    private(set) var prompts: [String] = []
    /// Opens once a `park` turn has written its file and waits.
    let parked = ACPLifecycleGate()
    /// Never opened: a parked turn ends only by being cancelled.
    private let never = ACPLifecycleGate()

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) {
        self.orchestrator = orchestrator
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        workspaces[id] = cwd
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
        guard workspaces[id] == nil else { return }
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
        workspaces.removeValue(forKey: id)
    }

    func shutdown() async {
        workspaces.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "summary-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let parts = prompt.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let workspace = workspaces[sessionID] else {
            await onEvent(.content("Nothing to change."))
            return DirectAgentResponse(text: "Nothing to change.", stopReason: "end_turn", modelID: "summary-model")
        }
        let ending = parts[0]
        let name = parts[1]
        let hasGraph = ending == "graph"
        if hasGraph, let orchestrator {
            try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(id: "write", title: "Write \(name)")]
            )
            try await orchestrator.updateTask(
                sessionID: sessionID, taskID: "write", update: TaskUpdate(status: .inProgress)
            )
        }

        await onEvent(.content("Writing."))
        let call = DirectAgentToolCall(
            id: "write-\(name)",
            name: "local.writeFile",
            argumentsObject: ["path": name, "content": "hello\n"],
            argumentsJSON: "{}"
        )
        await onEvent(.toolCallStarted(call))
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: workspace).appendingPathComponent(name))
        await onEvent(.toolCallCompleted(call, DirectAgentToolResult(
            output: "Wrote \(name)",
            summary: "Wrote \(name)",
            fileChanges: [OperationFileChange(path: name, oldText: nil, newText: "hello\n")]
        )))

        switch ending {
        case "fail":
            throw SummaryBackendFailure()
        case "cancel":
            throw CancellationError()
        case "park":
            parked.open()
            try await never.waitCancelling()
            try Task.checkCancellation()
        default:
            break
        }
        if hasGraph, let orchestrator {
            try await orchestrator.updateTask(
                sessionID: sessionID, taskID: "write",
                update: TaskUpdate(status: .completed, output: "Written")
            )
        }
        await onEvent(.content("All done."))
        return DirectAgentResponse(text: "Writing.All done.", stopReason: "end_turn", modelID: "summary-model")
    }
}

private struct SummaryFixture {
    let bridge: ZenCODEACPBridge
    let backend: SummaryBackend
    let wire: SummaryWire
    let sessionID: String

    /// One `session/prompt`, as a client writes it.
    func prompt(_ text: String, id: Int) async {
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]],
            ] as [String: Any],
        ])
    }

    /// One `session/cancel`, the notification a client sends.
    func cancel() async {
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID],
        ])
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ACPFileChangeSummaryPresentationTests {
    /// The Summary of one new file, `hello\n`, as a separated Markdown section
    /// with highlighted `/undo` and `/changes` actions.
    private static func summaryText(of name: String) -> String {
        "---\n**🪬 Summary: 1 file  +1 -0**\n  added \(name)  +1 -0\n"
            + "**`/undo`** to revert · **`/changes diff`** to show patches.\n---\n"
    }

    private static func withFixture(
        appMode: Bool = false,
        _ body: (SummaryFixture) async throws -> Void
    ) async throws {
        let sessionID = "acp-summary-\(UUID().uuidString)"
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let backend = SummaryBackend()
        let wire = SummaryWire()
        let bridge = ZenCODEACPBridge(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(
                        id: "test-model",
                        kind: .remoteAPI,
                        modelID: "local/test-model"
                    ),
                ],
                runMode: .acp,
                workingDirectory: workspace,
                appMode: appMode
            ),
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workspace,
            systemPrompt: "ACP file-change summary test",
            cacheKey: nil,
            history: [],
            allowedToolNames: nil
        )
        try await bridge.sessionRunner.createSession(configuration: sessionConfiguration)
        await bridge.installTestSession(sessionConfiguration)
        await backend.installTaskOrchestrator(bridge.sessionRunner.taskOrchestrator)
        do {
            try await body(SummaryFixture(bridge: bridge, backend: backend, wire: wire, sessionID: sessionID))
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    // MARK: - The text

    @Test
    func theSummaryIsASeparatedMarkdownSectionWithHighlightedCommands() throws {
        func entry(existedBefore: Bool, beforeData: String?) -> TurnFileChangeSummary.Entry {
            .init(
                path: "Sources/App.swift", additions: 3, deletions: 1, status: .modified,
                isBinary: false, existedBefore: existedBefore, beforeDataBase64: beforeData, patch: nil
            )
        }
        let undoable = TurnFileChangeSummary(entries: [
            entry(existedBefore: true, beforeData: Data("before\n".utf8).base64EncodedString()),
        ])
        let update = try #require(ACPFileChangeSummaryPresentation.update(for: undoable))
        #expect(update == ZenCODEACPBridge.textChunkJSONUpdate(
            kind: "agent_message_chunk",
            text: "---\n**🪬 Summary: 1 file  +3 -1**\n"
                + "  modified Sources/App.swift  +3 -1\n"
                + "**`/undo`** to revert · **`/changes diff`** to show patches.\n---\n"
        ))
        #expect(update.objectValue?["sessionUpdate"] == .string("agent_message_chunk"))

        // A summary the operator cannot undo says so, as the other channels do.
        let notUndoable = TurnFileChangeSummary(entries: [entry(existedBefore: true, beforeData: nil)])
        let text = try #require(
            ACPFileChangeSummaryPresentation.update(for: notUndoable)?
                .objectValue?["content"]?.objectValue?["text"]?.stringValue
        )
        #expect(text == "---\n**🪬 Summary: 1 file  +3 -1**\n"
            + "  modified Sources/App.swift  +3 -1\n"
            + "Undo is not available for this summary.\n---\n")

        // A turn that changed nothing presents nothing.
        #expect(ACPFileChangeSummaryPresentation.update(for: nil) == nil)
        #expect(ACPFileChangeSummaryPresentation.update(for: TurnFileChangeSummary(entries: [])) == nil)
    }

    /// The controller reports the Summary while the turn still runs, before the
    /// final plan: the presenter leaves it to the bridge, which presents it as
    /// the last text section once the turn has ended.
    @Test
    func thePresenterWritesNothingWhenTheControllerReportsTheSummary() async {
        let wire = SummaryWire()
        let presenter = ACPPromptPresenter(
            sessionID: "summary-session",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            writer: ACPWriter(sink: wire.sink),
            updatePipeline: nil,
            ensureTasklessObserver: {},
            claimDelegatedToolNotification: { _ in true }
        )
        let summary = TurnFileChangeSummary(entries: [
            .init(
                path: "Sources/App.swift", additions: 3, deletions: 1, status: .modified,
                isBinary: false, existedBefore: true, beforeDataBase64: nil, patch: nil
            ),
        ])

        await presenter.presentAssistantContent("Done.")
        await presenter.presentFileChangeSummary(summary)

        #expect(wire.timeline() == ["message:Done."])
    }

    // MARK: - Success

    /// A turn that changed a file ends with the Summary, and the reply of the
    /// prompt follows it: nothing is written between the two.
    @Test
    func aSuccessfulTurnEndsWithTheSummaryBeforeTheReply() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("success:notes.txt", id: 2)

            let timeline = fixture.wire.timeline()
            let summary = "message:" + Self.summaryText(of: "notes.txt")
            #expect(timeline.suffix(3) == ["message:All done.", summary, "result:2:end_turn"])
            #expect(timeline.filter { $0 == summary }.count == 1)

            // The file edit still reaches the client as the diff of its tool
            // call, before the model's closing text.
            let toolCall = try #require(timeline.firstIndex(of: "tool_call"))
            #expect(toolCall < (timeline.firstIndex(of: "message:All done.") ?? 0))

            // The turn keeps the Summary for `/changes` and `/undo`; the model
            // only ever saw the operator's prompt (the Summary is written to the
            // wire and nowhere else).
            #expect(await fixture.bridge.lastSummaryPaths(sessionID: fixture.sessionID) == ["notes.txt"])
            #expect(await fixture.backend.prompts == ["success:notes.txt"])
        }
    }

    /// The final plan of the turn is written first: the Summary is the last
    /// text section, after the plan and the closing text of the model.
    @Test
    func theSummaryFollowsTheFinalPlanOfTheTurn() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("graph:notes.txt", id: 2)

            let timeline = fixture.wire.timeline()
            let summary = "message:" + Self.summaryText(of: "notes.txt")
            let summaryIndex = try #require(timeline.firstIndex(of: summary))
            let lastPlan = try #require(timeline.lastIndex(of: "plan"))
            let closingText = try #require(timeline.firstIndex(of: "message:All done."))
            #expect(lastPlan < summaryIndex)
            #expect(closingText < summaryIndex)
            #expect(timeline[(summaryIndex + 1)...] == ["result:2:end_turn"])
            // What the plan said last is where the task ended.
            #expect(fixture.wire.planStatuses().last == ["completed"])
        }
    }

    /// In app mode the text is buffered: the Summary is flushed with the turn,
    /// ends the text the client received, and is followed by the reply only.
    @Test
    func inAppModeTheBufferedSummaryStillEndsTheTextBeforeTheReply() async throws {
        try await Self.withFixture(appMode: true) { fixture in
            await fixture.prompt("success:notes.txt", id: 2)

            let timeline = fixture.wire.timeline()
            #expect(timeline.last == "result:2:end_turn")
            let lastText = try #require(fixture.wire.messageTexts().last)
            #expect(lastText.hasSuffix(Self.summaryText(of: "notes.txt")))
            let received = fixture.wire.messageTexts().joined()
            #expect(received.components(separatedBy: "🪬 Summary:").count == 2)
            #expect(timeline.dropLast().last?.hasPrefix("message:") == true)
        }
    }

    @Test
    func aTurnThatChangedNoFilePresentsNoSummary() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("nothing to change", id: 2)

            #expect(fixture.wire.timeline().suffix(2) == ["message:Nothing to change.", "result:2:end_turn"])
            #expect(!fixture.wire.messageTexts().contains { $0.contains("Summary:") })
        }
    }

    /// Each turn presents the files it changed itself: a later turn does not
    /// repeat the Summary of an earlier one.
    @Test
    func everyTurnPresentsOnlyItsOwnSummary() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("success:first.txt", id: 2)
            await fixture.prompt("nothing to change", id: 3)
            await fixture.prompt("success:second.txt", id: 4)

            let summaries = fixture.wire.messageTexts().filter { $0.contains("🪬 Summary:") }
            #expect(summaries == [Self.summaryText(of: "first.txt"), Self.summaryText(of: "second.txt")])
            let timeline = fixture.wire.timeline()
            let plain = try #require(timeline.firstIndex(of: "result:3:end_turn"))
            #expect(!timeline[..<plain].suffix(2).contains { $0.contains("Summary:") })
        }
    }

    // MARK: - Error and cancellation

    /// A turn that failed after it changed a file still tells which, before the
    /// error that answers the prompt.
    @Test
    func aFailedTurnPresentsTheSummaryBeforeTheError() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("fail:notes.txt", id: 2)

            let timeline = fixture.wire.timeline()
            #expect(timeline.suffix(2) == ["message:" + Self.summaryText(of: "notes.txt"), "error:2"])
            #expect(!timeline.contains { $0.hasPrefix("result:2") })
        }
    }

    /// A turn that ends cancelled while its prompt still holds the session (the
    /// provider gave up; nobody sent `session/cancel`) is still authorized to
    /// present: the Summary comes before the `cancelled` reply.
    @Test
    func aCancelledTurnThatStillHoldsThePromptPresentsTheSummary() async throws {
        try await Self.withFixture { fixture in
            await fixture.prompt("cancel:notes.txt", id: 2)

            #expect(fixture.wire.timeline().suffix(2)
                == ["message:" + Self.summaryText(of: "notes.txt"), "result:2:cancelled"])
        }
    }

    /// `session/cancel` takes the prompt away from the turn before it unwinds:
    /// the Summary it would present is a late update the fence refuses, as it
    /// refuses the rest of the turn's presentation. The reply is the last text
    /// the client gets, and `/changes` and `/undo` still have the Summary.
    @Test
    func sessionCancelFencesTheSummaryOfTheCancelledTurn() async throws {
        try await Self.withFixture { fixture in
            let running = Task { await fixture.prompt("park:notes.txt", id: 2) }
            await fixture.backend.parked.wait()
            await fixture.cancel()
            await running.value

            let timeline = fixture.wire.timeline()
            #expect(!fixture.wire.messageTexts().contains { $0.contains("Summary:") })
            let reply = try #require(timeline.firstIndex(of: "result:2:cancelled"))
            // The file edit made before the cancel reached the client; no text
            // follows the reply (a plan reconciliation is not text).
            #expect(timeline[..<reply].contains("tool_call_update"))
            #expect(!timeline[(reply + 1)...].contains { $0.hasPrefix("message:") })

            #expect(await fixture.bridge.lastSummaryPaths(sessionID: fixture.sessionID) == ["notes.txt"])
        }
    }

    /// After a cancelled turn the next prompt presents its own Summary again:
    /// the fence ended with the turn it fenced.
    @Test
    func theTurnAfterACancelledOneStillPresentsItsSummary() async throws {
        try await Self.withFixture { fixture in
            let running = Task { await fixture.prompt("park:first.txt", id: 2) }
            await fixture.backend.parked.wait()
            await fixture.cancel()
            await running.value

            await fixture.prompt("success:second.txt", id: 3)

            let timeline = fixture.wire.timeline()
            #expect(timeline.suffix(2) == ["message:" + Self.summaryText(of: "second.txt"), "result:3:end_turn"])
            #expect(fixture.wire.messageTexts().filter { $0.contains("🪬 Summary:") }
                == [Self.summaryText(of: "second.txt")])
        }
    }
}

extension ZenCODEACPBridge {
    /// The paths of the Summary `/changes` and `/undo` read in `sessionID`.
    fileprivate func lastSummaryPaths(sessionID: String) async -> [String]? {
        await sessions[sessionID]?.controller.lastFileChangeSummary?.entries.map(\.path)
    }
}
