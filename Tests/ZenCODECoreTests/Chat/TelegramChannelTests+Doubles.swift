//
//  TelegramChannelTests+Doubles.swift
//  ZenCODE
//
//  The scripted runtime backend and the primary channel presenter that the
//  Telegram channel tests run a slot with.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// A runtime backend whose turns follow a script per prompt: streamed
/// content, a pause until the test releases it, a gated tool asked through
/// the runner's authorization, and the reply.
actor TelegramChannelTestBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        case content(String)
        case pause
        case askPermission(command: String)
    }

    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    private(set) var permissionDecisions: [Bool] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedCount = 0
    private var releasedCount = 0
    private let authorization = Mutex<AgentToolAuthorizationHandler?>(nil)

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] configuration, _ in
            authorization.withLock { $0 = configuration.toolAuthorizationHandler }
            return self
        }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    /// Whether a turn waits at a `.pause` step.
    var isPaused: Bool {
        pausedCount > releasedCount
    }

    /// Lets the turn waiting at a `.pause` step go on.
    func release() {
        releasedCount += 1
        if !pauseWaiters.isEmpty {
            pauseWaiters.removeFirst().resume()
        }
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.content("Answer to: \(prompt)")] : scripts.removeFirst()
        var text = ""
        for (index, step) in steps.enumerated() {
            switch step {
            case let .content(content):
                text += content
                await onEvent(.content(content))
            case .pause:
                pausedCount += 1
                if releasedCount < pausedCount {
                    await withCheckedContinuation { pauseWaiters.append($0) }
                }
            case let .askPermission(command):
                let handler = authorization.withLock { $0 }
                let request = AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: "exec-\(index)",
                    toolName: "local.exec",
                    title: "Run \(command)",
                    kind: "execute",
                    command: command,
                    workingDirectory: sessions[sessionID]?.workingDirectoryPath ?? "/tmp"
                )
                let approved = await handler?(request) ?? false
                permissionDecisions.append(approved)
            }
        }
        if var snapshot = sessions[sessionID] {
            snapshot = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID, modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt, cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: text),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
            sessions[sessionID] = snapshot
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

/// The primary channel of the tests: a presenter that records the turn
/// output it receives and presents the endings of the turns, and an
/// interaction host that records what it is asked and answers what the test
/// scripted.
@ChatSessionActor
final class PrimaryChannelPresenter: ChatSlotChannelPresenter {
    private(set) var assistantText = ""
    private(set) var movedTurns: [ChatMovedTurn] = []
    private(set) var endings: [ChatTurnEnding] = []
    private(set) var turnStarts = 0

    init() {}

    func turnWillStart(_ request: ChatTurnRequest) async {
        turnStarts += 1
    }

    func presentAssistantContent(_ content: String) async {
        assistantText += content
    }

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {
        movedTurns.append(turn)
    }

    func presentTurnEnding(_ ending: ChatTurnEnding) async {
        endings.append(ending)
    }
}
