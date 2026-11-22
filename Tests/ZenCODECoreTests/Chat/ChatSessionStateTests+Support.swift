//
//  ChatSessionStateTests+Support.swift
//  ZenCODE
//
//  Static helpers shared by the chat session state tests: representable
//  entries, reducer factories, request builders and the comparison turns.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

// MARK: - Helpers

extension ChatSessionStateTests {
    /// An entry the transcript can represent, reduced to what it keeps.
    enum RepresentableEntry: Equatable, Sendable {
        case prompt(text: String, attachments: [AgentRuntimeAttachment])
        case assistantText(String)
        case thought(String)
        case toolCallStarted(id: String, name: String, argumentsJSON: String)
        case toolCallCompleted(id: String, name: String, output: String, attachments: [AgentRuntimeAttachment])

        init?(_ kind: ChatTurnEntry.Kind) {
            switch kind {
            case let .userPrompt(text, attachments, _):
                self = .prompt(text: text, attachments: attachments)
            case let .assistantText(text):
                self = .assistantText(text)
            case let .thought(text):
                self = .thought(text)
            case let .toolCallStarted(call):
                self = .toolCallStarted(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)
            case let .toolCallCompleted(call, result):
                self = .toolCallCompleted(
                    id: call.id, name: call.name, output: result.output, attachments: result.attachments
                )
            default:
                return nil
            }
        }
    }

    /// A representable entry with its turn, numbered from 1 in log order.
    struct TurnEntry: Equatable, Sendable {
        let turn: Int?
        let entry: RepresentableEntry
    }

    static func representable(_ log: [ChatTurnEntry]) -> [TurnEntry] {
        var ordinals: [Int: Int] = [:]
        return log.compactMap { entry in
            guard let representable = RepresentableEntry(entry.kind) else { return nil }
            let turn = entry.turnID.map { turnID in
                if let ordinal = ordinals[turnID] { return ordinal }
                let ordinal = ordinals.count + 1
                ordinals[turnID] = ordinal
                return ordinal
            }
            return TurnEntry(turn: turn, entry: representable)
        }
    }

    /// A reducer that received `messages` as a restored session, through the
    /// one transcript rebuild.
    @ChatSessionActor
    static func reducerRestoring(_ messages: [AgentRuntimeMessage]) async -> ChatSessionStateReducer {
        let reducer = reducer()
        await reducer.presentRestoredLog(ChatTurnEntry.kinds(fromTranscript: messages))
        return reducer
    }

    static func expectStrictlyIncreasing(
        _ log: [ChatTurnEntry],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (previous, next) in zip(log, log.dropFirst()) {
            #expect(previous.sequence < next.sequence, sourceLocation: sourceLocation)
        }
    }

    /// The projections are the log filtered by kind, in log order.
    static func expectCoherentProjections(
        _ snapshot: ChatSessionSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let union = (snapshot.transcript + snapshot.activity).sorted { $0.sequence < $1.sequence }
        #expect(union == snapshot.log.filter { $0.kind.isTranscriptOrActivity }, sourceLocation: sourceLocation)
        #expect(snapshot.transcript == snapshot.log.filter { $0.kind.isTranscript }, sourceLocation: sourceLocation)
        #expect(snapshot.activity == snapshot.log.filter { $0.kind.isActivity }, sourceLocation: sourceLocation)
        #expect(
            snapshot.notices == Array(snapshot.log.filter { $0.kind.isNotice }
                .suffix(ChatSessionStateReducer.maximumNoticeCount)),
            sourceLocation: sourceLocation
        )
        #expect(
            snapshot.fileChanges.artifactHistory == snapshot.log.filter { $0.kind.isFileArtifacts },
            sourceLocation: sourceLocation
        )
        #expect(snapshot.log.first.map { $0.sequence >= snapshot.firstRetainedSequence } ?? true,
                sourceLocation: sourceLocation)
    }

    /// The first snapshot of `reducer`, the current one included, that
    /// satisfies `predicate`.
    @ChatSessionActor
    static func snapshot(
        of reducer: ChatSessionStateReducer,
        where predicate: (ChatSessionSnapshot) -> Bool
    ) async -> ChatSessionSnapshot {
        for await snapshot in reducer.snapshots() where predicate(snapshot) {
            return snapshot
        }
        Issue.record("The snapshot stream ended")
        return reducer.snapshot
    }

    static func reducer(maximumLogBytes: Int = ChatSessionController.maximumTranscriptBytes) -> ChatSessionStateReducer {
        ChatSessionStateReducer(
            sessionID: "state-session",
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("chat-state-\(UUID().uuidString)", isDirectory: true),
            defaultOrigin: .local,
            state: ChatSessionState(),
            epoch: 0,
            maximumLogBytes: maximumLogBytes
        )
    }

    static func toolCall(id: String, name: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: name, argumentsObject: ["path": "."], argumentsJSON: "{}")
    }

    static func response(_ text: String) -> DirectAgentResponse {
        DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "m")
    }

    static func artifactTurn(number: UInt64, path: String) -> SessionFileArtifactHistory.Turn {
        SessionFileArtifactHistory.Turn(
            number: number,
            artifacts: [FileChangeArtifact(absolutePath: "/tmp/\(path)", displayPath: path, status: .modified)]
        )
    }

    /// A request outside any controller, for the reducer alone.
    static func request(
        _ prompt: String,
        purpose: ChatTurnPurpose = .normal,
        origin: ChatTurnOrigin? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            purpose: purpose,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: "state-session",
                modelID: "scripted-model",
                workingDirectory: FileManager.default.temporaryDirectory,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            origin: origin
        )
    }

    /// A request for a turn of `controller`'s session.
    @ChatSessionActor
    static func request(
        _ prompt: String,
        for controller: ChatSessionController,
        attachments: [AgentRuntimeAttachment] = [],
        presenter: (any ChatSessionPresenter)? = nil,
        origin: ChatTurnOrigin? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            attachments: attachments,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: controller.sessionID,
                modelID: "scripted-model",
                workingDirectory: controller.workingDirectory,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            presenter: presenter,
            origin: origin
        )
    }

    /// The saved session `name` as the project's store holds it.
    @ChatSessionActor
    static func stored(_ name: String, in harness: ChatManagementHarness) throws -> TerminalSavedSession {
        try #require(try TerminalSessionStore.savedSessions(for: harness.workspace).first { $0.name == name })
    }

    /// A turn with reasoning, content, and two tool calls.
    static let inspectionTurn: ScriptedChatRuntime.Script = { call in
        let read = toolCall(id: "tool-read", name: "local.read")
        await call.onEvent(.thought("Planning. "))
        await call.onEvent(.content("Let me check."))
        await call.onEvent(.toolCallStarted(read))
        await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "ok", summary: "ok")))
        await call.onEvent(.content("Done."))
        await call.onEvent(.turnEnded(.completed))
        return DirectAgentResponse(text: "Let me check.Done.", stopReason: "end_turn", modelID: "m")
    }

    /// Three turns: tool calls with an attachment and a blank block, a turn
    /// of reasoning alone, and a failed turn with a completion that never
    /// started. 15 representable entries.
    @ChatSessionActor
    static func runComparisonTurns(
        on controller: ChatSessionController,
        runtime: ScriptedChatRuntime,
        request: @ChatSessionActor (String, [AgentRuntimeAttachment]) -> ChatTurnRequest
    ) async throws {
        let shot = AgentRuntimeAttachment(
            kind: .image,
            data: Data([1, 2, 3]),
            contentType: "image/png",
            originalFilename: "shot.png"
        )
        await runtime.append { call in
            let read = toolCall(id: "tool-read", name: "local.read")
            let list = DirectAgentToolCall(
                id: "tool-list", name: "local.ls", argumentsObject: ["path": "Sources", "depth": 2], argumentsJSON: "{}"
            )
            await call.onEvent(.thought("Planning the reads. "))
            await call.onEvent(.content("Let me "))
            await call.onEvent(.content("check."))
            await call.onEvent(.toolCallStarted(read))
            await call.onEvent(.toolCallCompleted(read, DirectAgentToolResult(output: "ok", summary: "ok", attachments: [shot])))
            await call.onEvent(.content("\n"))
            await call.onEvent(.toolCallStarted(list))
            await call.onEvent(.toolCallCompleted(list, DirectAgentToolResult(output: "a\nb", summary: "2 entries")))
            await call.onEvent(.thought("Wrapping up."))
            await call.onEvent(.content("Final answer."))
            await call.onEvent(.turnEnded(.completed))
            return DirectAgentResponse(text: "Let me check.Final answer.", stopReason: "end_turn", modelID: "m")
        }
        _ = try await controller.runTurn(request("Inspect the project", [shot]))

        await runtime.append { call in
            await call.onEvent(.thought("Only reasoning here."))
            await call.onEvent(.turnEnded(.completed))
            return DirectAgentResponse(text: "Promoted answer.", stopReason: "end_turn", modelID: "m")
        }
        _ = try await controller.runTurn(request("Why?", []))

        await runtime.append { call in
            let orphan = toolCall(id: "tool-orphan", name: "local.exec")
            await call.onEvent(.content("Partial"))
            await call.onEvent(.toolCallCompleted(orphan, DirectAgentToolResult(output: "denied", summary: "denied", status: .permissionDenied)))
            throw ScriptedChatRuntime.ScriptedFailure(message: "backend failed")
        }
        _ = try? await controller.runTurn(request("Run it", []))
    }

    /// A short label of an entry, for compact expectations.
    static func label(_ kind: ChatTurnEntry.Kind) -> String {
        switch kind {
        case let .userPrompt(text, _, _): "prompt:\(text)"
        case .assistantText: "text"
        case .thought: "thought"
        case .toolCallStarted: "toolStarted"
        case .toolCallCompleted: "toolCompleted"
        case .fileArtifacts: "artifacts"
        case .notice: "notice"
        case .workflowNotice: "workflow"
        case .turnPhase(.started): "started"
        case .turnPhase(.modelReturned): "modelReturned"
        case .turnPhase(.finishing): "finishing"
        case .turnPhase(.ended): "ended"
        }
    }
}

extension ChatTurnEntry.Kind {
    var isTranscriptOrActivity: Bool {
        isTranscript || isActivity
    }
}
