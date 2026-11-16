//
//  ACPTelegramTestSupport+ScriptedBackend.swift
//  ZenCODE
//
//  Scripted agent runtime backend for the ACP Telegram tests: it replays
//  queued steps, records prompts, permission decisions, session writes and
//  client file accesses, and can pause a turn on demand.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Model backend

/// A model backend whose prompts follow the script of ``enqueue(_:)``, one
/// list of steps per prompt; a prompt without a script answers `reply`. It
/// keeps the history of every session, so the runner's snapshot (and ACP's
/// `session/load` replay) carries the turns it ran, and records the system
/// prompt and the tool grant of every session write, so a test can tell how
/// a turn was composed. The runtime's authorization handler is captured
/// from the configuration the backend factory receives (see ``factory``).
actor ACPTelegramScriptedBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        /// Streams `text` as model content.
        case reply(String)
        /// Waits until ``release()`` lets the prompt go on.
        case pause
        /// Writes `contents` to `path`, relative to the session's directory,
        /// through a reported `local.writeFile` tool call.
        case writeFile(path: String, contents: String)
        /// Asks permission to run `command` with `local.exec`, as a gated
        /// tool call would, and records the decision; a prompt cancelled
        /// while it waited ends there, as a model turn does.
        case askPermission(command: String)
        /// Reads `path`, relative to the session's directory, through the text
        /// file system the turn runs in (``ClientTextFileSystem/current``) and
        /// records what it saw in ``clientFileAccesses``; without one, from
        /// the disk.
        case readClientFile(path: String)
        /// Writes `contents` to `path`, relative to the session's directory,
        /// through the text file system the turn runs in, as the file tools
        /// do, and records it in ``clientFileAccesses``; without one, to the
        /// disk.
        case writeClientFile(path: String, contents: String)
    }

    /// A file access a turn made through ``Step/readClientFile(path:)`` or
    /// ``Step/writeClientFile(path:contents:)``: whether the turn ran inside a
    /// client text file system, and what a read returned.
    struct ClientFileAccess: Equatable, Sendable {
        let hadClientFileSystem: Bool
        let readContents: String?
    }

    /// A session write the backend received: the system prompt and the
    /// tool grant of a `createSession`, `createSessionIfNeeded`, or
    /// `updateSessionOptions`.
    struct SessionWrite: Equatable, Sendable {
        let systemPrompt: String?
        let allowedToolNames: Set<String>?
    }

    private let authorization = Mutex<AgentToolAuthorizationHandler?>(nil)
    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    private(set) var permissionDecisions: [Bool] = []
    private(set) var sessionWrites: [SessionWrite] = []
    private(set) var clientFileAccesses: [ClientFileAccess] = []
    private var permissionAskCount = 0
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedCount = 0
    private var releasedCount = 0

    /// The backend factory of a bridge using this backend.
    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] configuration, _ in
            authorization.withLock { $0 = configuration.toolAuthorizationHandler }
            return self
        }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    /// How many permissions were asked so far, answered or not.
    var askedPermissionCount: Int {
        permissionAskCount
    }

    /// Whether a prompt waits at a `.pause` step.
    var isPaused: Bool {
        pausedCount > releasedCount
    }

    /// Lets the prompt waiting at a `.pause` step go on.
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
        sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
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
        guard sessions[id] == nil else {
            sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
            return
        }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt: String?, allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {
        sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
    }

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

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.reply("reply")] : scripts.removeFirst()
        let directory = URL(fileURLWithPath: sessions[sessionID]?.workingDirectoryPath ?? FileManager.default.currentDirectoryPath)
        var text = ""
        for (index, step) in steps.enumerated() {
            switch step {
            case let .reply(reply):
                text += reply
                await onEvent(.content(reply))
            case .pause:
                pausedCount += 1
                if releasedCount < pausedCount {
                    await withCheckedContinuation { pauseWaiters.append($0) }
                }
                try Task.checkCancellation()
            case let .writeFile(path, contents):
                let write = DirectAgentToolCall(
                    id: "write-\(index)",
                    name: "local.writeFile",
                    argumentsObject: ["path": path, "content": contents],
                    argumentsJSON: "{}"
                )
                await onEvent(.toolCallStarted(write))
                try Data(contents.utf8).write(to: directory.appendingPathComponent(path))
                await onEvent(.toolCallCompleted(write, DirectAgentToolResult(
                    output: "Wrote \(path)",
                    summary: "Wrote \(path)",
                    fileChanges: [OperationFileChange(path: path, oldText: nil, newText: contents)]
                )))
            case let .askPermission(command):
                permissionAskCount += 1
                let handler = authorization.withLock { $0 }
                let request = AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: "exec-\(index)",
                    toolName: "local.exec",
                    title: "Run \(command)",
                    kind: "execute",
                    command: command,
                    workingDirectory: directory.path
                )
                let approved = await handler?(request) ?? false
                permissionDecisions.append(approved)
                try Task.checkCancellation()
            case let .readClientFile(path):
                let url = directory.appendingPathComponent(path)
                let client = ClientTextFileSystem.current
                let contents: String?
                if let read = client?.read {
                    contents = try await read(url)
                } else {
                    contents = try? String(contentsOf: url, encoding: .utf8)
                }
                clientFileAccesses.append(ClientFileAccess(
                    hadClientFileSystem: client != nil, readContents: contents
                ))
            case let .writeClientFile(path, contents):
                let url = directory.appendingPathComponent(path)
                let client = ClientTextFileSystem.current
                if let write = client?.write {
                    try await write(url, contents)
                } else {
                    try Data(contents.utf8).write(to: url)
                }
                clientFileAccesses.append(ClientFileAccess(
                    hadClientFileSystem: client != nil, readContents: nil
                ))
            }
        }
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
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
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }
}
