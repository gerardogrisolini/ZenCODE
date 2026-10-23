//
//  RealtimeGenerationClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation
import ToolCore

/// The prompt carried by a turn that answers committed user speech. The
/// spoken input already lives in the provider conversation, so the turn only
/// asks for a response.
public enum OpenAIRealtimeVoiceTurn {
    public static let promptMarker = "🎤"
}

/// Presentation-side handle for one subscription to a realtime backend's
/// voice events. Audio is forwarded to the live conversation and is never
/// persisted. The handle does not keep its backend alive.
public struct OpenAIRealtimeVoiceLink: Sendable {
    public let modelID: String
    public let events: AsyncStream<OpenAIRealtimeVoiceEvent>
    private let appendAudio: @Sendable (Data) async -> Void
    private let playback: @Sendable (String, Int) async -> Void

    init(
        modelID: String,
        events: AsyncStream<OpenAIRealtimeVoiceEvent>,
        appendAudio: @escaping @Sendable (Data) async -> Void,
        playback: @escaping @Sendable (String, Int) async -> Void
    ) {
        self.modelID = modelID
        self.events = events
        self.appendAudio = appendAudio
        self.playback = playback
    }

    /// Appends little-endian PCM16 mono 24 kHz microphone audio.
    public func appendInputAudio(_ pcm16: Data) async {
        await appendAudio(pcm16)
    }

    /// Reports the cumulative milliseconds of an assistant audio item that
    /// were actually played, which drives barge-in truncation.
    public func reportPlayback(itemID: String, playedMilliseconds: Int) async {
        await playback(itemID, playedMilliseconds)
    }
}

/// Backends able to expose a live voice link. Internal so the capability stays
/// an implementation detail of the realtime backend.
protocol RealtimeVoiceCapableBackend: AgentRuntimeBackend {
    func voiceLink(sessionID: String) async throws -> OpenAIRealtimeVoiceLink
}

/// Coordinator backend for OpenAI `gpt-realtime*` models.
///
/// One realtime WebSocket conversation serves one agent session. The
/// conversation is intentionally transient: history passed by the runner is
/// not replayed (only its session-context block is kept as instructions),
/// `snapshotSession` returns `nil`, and a lost or expired connection is
/// replaced by an empty one.
public actor RealtimeGenerationClient: DirectToolRuntimeBackend, RealtimeVoiceCapableBackend {
    struct SessionState: Sendable {
        let id: String
        var cwd: URL
        var systemPrompt: String?
        var dynamicContext: String?
        var allowedToolNames: Set<String>?
    }

    private struct ConnectionSettings: Sendable {
        let instructions: String
        let tools: [JSONValue]
        let catalog: RemoteToolWireCatalog
        let fingerprint: String
        let estimatedTokens: Int
    }

    static let toolOutputCharacterLimit = 12_000
    static let configurationTokenWarningThreshold = 14_000
    static let restartDiagnostic = "Voice session restarted; earlier conversation is not carried over."
    static let configurationBudgetDiagnostic = "Voice session configuration is close to the provider limit; consider fewer tools or shorter instructions."
    static let voicePreamble = """
    You are speaking with the user through a live voice conversation.
    - Answer with short, natural spoken sentences. Never use Markdown, lists, tables, code blocks or emoji.
    - Summarize tool results instead of reading them verbatim.
    - Before calling any tool with confirm=true, describe the action and wait for the user's explicit spoken confirmation.
    - Delegated agents report back later in separate turns; when their results arrive, announce them briefly.
    """

    public let configuration: AgentRuntimeConfiguration
    public let provider: AgentRemoteProvider
    public let toolExecutor: DirectToolExecutor
    private let apiKey: String?
    private let transport: RemoteTransportCore
    private let ownsTransport: Bool
    private let webSocketURLOverride: URL?

    private var sessions: [String: SessionState] = [:]
    private var connection: OpenAIRealtimeSession?
    private var connectionSessionID: String?
    private var connectionFingerprint: String?
    private var toolCatalog = RemoteToolWireCatalog(descriptors: [])
    private var connectTask: Task<OpenAIRealtimeSession, any Error>?
    private var connectTaskSessionID: String?
    private var forwardingTask: Task<Void, Never>?
    private var voiceSubscriber: AsyncStream<OpenAIRealtimeVoiceEvent>.Continuation?
    private var hasConnectedBefore = false
    private var pendingDiagnostics: [String] = []
    private var didEmitLoadedModel = false
    private var isShutdown = false

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        transport: RemoteTransportCore? = nil,
        /// Loopback tests point the client at a local WebSocket server.
        webSocketURLOverride: URL? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.provider = provider
        self.apiKey = apiKey?.nilIfBlank
        self.transport = transport ?? RemoteTransportCore()
        ownsTransport = transport == nil
        self.webSocketURLOverride = webSocketURLOverride
        toolExecutor = RemoteGenerationClient.makeToolExecutor(
            configuration: configuration,
            provider: provider,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory
        )
    }

    // MARK: - Sessions

    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        // Conversation history is never replayed into a voice conversation;
        // only the leading session-context block is kept as instructions.
        sessions[id] = SessionState(
            id: id,
            cwd: URL(fileURLWithPath: cwd).standardizedFileURL,
            systemPrompt: systemPrompt,
            dynamicContext: AgentRuntimeDynamicContext.separating(from: history).context,
            allowedToolNames: allowedToolNames
        )
        scheduleConfigurationSync(sessionID: id)
    }

    public func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        guard sessions[id] == nil else {
            return
        }
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

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        session.systemPrompt = systemPrompt
        session.allowedToolNames = allowedToolNames
        sessions[id] = session
        scheduleConfigurationSync(sessionID: id)
    }

    public func closeSession(id: String) async {
        sessions.removeValue(forKey: id)
        if connectionSessionID == id || connectTaskSessionID == id {
            await retireConnection(finishingSubscriber: true)
        }
        await toolExecutor.removeToolProviders(sessionID: id)
    }

    public func shutdown() async {
        isShutdown = true
        await retireConnection(finishingSubscriber: true)
        sessions.removeAll()
        await toolExecutor.shutdown()
        if ownsTransport {
            try? await transport.shutdown()
        }
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        guard !isShutdown else {
            throw CancellationError()
        }
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(provider.modelID))
        }
        return provider.modelID
    }

    public func activeToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        let session = if let sessionID {
            sessions[sessionID]
        } else {
            sessions.values.first
        }
        guard let session else {
            return []
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
    }

    /// Voice conversations are never persisted.
    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    public func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        nil
    }

    // MARK: - Voice link

    func voiceLink(sessionID: String) async throws -> OpenAIRealtimeVoiceLink {
        guard !isShutdown else {
            throw CancellationError()
        }
        if sessions[sessionID] == nil {
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        let realtime = try await ensureConnected(sessionID: sessionID)
        let (events, continuation) = AsyncStream.makeStream(
            of: OpenAIRealtimeVoiceEvent.self,
            bufferingPolicy: .unbounded
        )
        voiceSubscriber?.finish()
        voiceSubscriber = continuation
        let isReady = await realtime.isReady
        if isReady, connection === realtime {
            continuation.yield(.connected)
        } else {
            let reason = await realtime.disconnectReason
            continuation.yield(.disconnected(reason ?? "Voice session closed."))
            continuation.finish()
        }
        return OpenAIRealtimeVoiceLink(
            modelID: provider.modelID,
            events: events,
            appendAudio: { [weak self] pcm16 in
                await self?.appendInputAudio(pcm16)
            },
            playback: { [weak self] itemID, playedMilliseconds in
                await self?.reportPlayback(itemID: itemID, playedMilliseconds: playedMilliseconds)
            }
        )
    }

    private func appendInputAudio(_ pcm16: Data) async {
        guard let connection else {
            return
        }
        await connection.appendInputAudio(pcm16)
    }

    private func reportPlayback(itemID: String, playedMilliseconds: Int) async {
        guard let connection else {
            return
        }
        await connection.reportPlayback(itemID: itemID, playedMilliseconds: playedMilliseconds)
    }

    private func forwardVoiceEvent(
        _ event: OpenAIRealtimeVoiceEvent,
        from realtime: OpenAIRealtimeSession
    ) {
        guard connection === realtime else {
            return
        }
        voiceSubscriber?.yield(event)
    }

    // MARK: - Prompt turns

    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        // Isolated memory proposals must never enter the voice conversation.
        guard !MemoryConsolidationContext.isIsolated else {
            throw CancellationError()
        }
        guard !isShutdown else {
            throw CancellationError()
        }
        if sessions[sessionID] == nil {
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        _ = try await preloadModel(onEvent: onEvent)

        let isVoiceTurn = prompt == OpenAIRealtimeVoiceTurn.promptMarker
        let hasPendingVoiceTurn = isVoiceTurn
            ? await hasPendingVoiceTurn(sessionID: sessionID)
            : false
        if isVoiceTurn, !hasPendingVoiceTurn {
            // An earlier response already answered this speech.
            return DirectAgentResponse(text: "", stopReason: "coalesced", modelID: provider.modelID)
        }

        let realtime = try await ensureConnected(sessionID: sessionID)
        try await syncConfigurationIfNeeded(sessionID: sessionID)
        await flushDiagnostics(onEvent)
        if !attachments.isEmpty {
            await onEvent(.diagnostic("Attachments are not sent to realtime voice sessions."))
        }
        if !isVoiceTurn {
            try await realtime.createUserTextItem(prompt)
        }
        try await realtime.createResponse()

        var responseText = ""
        for round in 0..<configuration.maxToolRounds {
            let result: OpenAIRealtimeResponseResult
            do {
                result = try await realtime.awaitResponseDone { delta in
                    await onEvent(.content(delta))
                }
            } catch is CancellationError {
                await realtime.cancelActiveResponse()
                throw CancellationError()
            }
            responseText += result.transcript

            switch result.status {
            case "cancelled":
                return DirectAgentResponse(
                    text: responseText,
                    stopReason: "cancelled",
                    modelID: provider.modelID
                )
            case "failed":
                throw result.failure
                    ?? OpenAIRealtimeSessionError.provider(code: nil, message: "The realtime response failed.")
            default:
                break
            }

            guard !result.functionCalls.isEmpty else {
                return DirectAgentResponse(
                    text: responseText,
                    stopReason: result.status == "incomplete" ? "length" : "stop",
                    modelID: provider.modelID
                )
            }

            guard let session = sessions[sessionID] else {
                throw RemoteGenerationClientError.missingSession
            }
            try await executeFunctionCalls(
                result.functionCalls,
                session: session,
                realtime: realtime,
                onEvent: onEvent
            )
            guard round < configuration.maxToolRounds - 1 else {
                break
            }
            try await realtime.createResponse()
        }
        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }

    private func hasPendingVoiceTurn(sessionID: String) async -> Bool {
        guard let connection, connectionSessionID == sessionID else {
            return false
        }
        guard await connection.isReady else {
            return false
        }
        return await connection.pendingCommittedTurns > 0
    }

    private func executeFunctionCalls(
        _ calls: [OpenAIRealtimeFunctionCall],
        session: SessionState,
        realtime: OpenAIRealtimeSession,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        var answeredCount = 0
        do {
            for call in calls {
                try Task.checkCancellation()
                guard let toolCall = localToolCall(for: call) else {
                    try await realtime.createFunctionCallOutput(
                        callID: call.callID,
                        output: "Tool error: the arguments for \(call.name) are not a valid JSON object."
                    )
                    answeredCount += 1
                    continue
                }
                await onEvent(.toolCallStarted(toolCall))
                let toolResult = await toolExecutor.execute(
                    sessionID: session.id,
                    toolCall: toolCall,
                    workingDirectory: session.cwd,
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(toolCall, toolResult))
                try await realtime.createFunctionCallOutput(
                    callID: call.callID,
                    output: Self.truncatedToolOutput(toolResult.modelOutput)
                )
                answeredCount += 1
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            // Close the batch so the conversation never holds an unanswered call.
            for call in calls.dropFirst(answeredCount) {
                try? await realtime.createFunctionCallOutput(
                    callID: call.callID,
                    output: "Tool execution cancelled before dispatch."
                )
            }
            throw CancellationError()
        }
    }

    private func localToolCall(for call: OpenAIRealtimeFunctionCall) -> DirectAgentToolCall? {
        let rawArguments = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: [String: Any]
        if rawArguments.isEmpty {
            arguments = [:]
        } else {
            guard let data = rawArguments.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            arguments = object
        }
        let wireCall = DirectAgentToolCall(
            id: call.callID,
            name: call.name,
            argumentsObject: arguments,
            argumentsJSON: rawArguments.isEmpty ? "{}" : rawArguments
        )
        return toolCatalog.localToolCall(from: wireCall)
    }

    static func truncatedToolOutput(_ output: String) -> String {
        guard output.count > toolOutputCharacterLimit else {
            return output
        }
        let omitted = output.count - toolOutputCharacterLimit
        return String(output.prefix(toolOutputCharacterLimit))
            + "\n[Output truncated: \(omitted) characters omitted.]"
    }

    // MARK: - Connection management

    private func ensureConnected(sessionID: String) async throws -> OpenAIRealtimeSession {
        while true {
            guard !isShutdown else {
                throw CancellationError()
            }
            if let current = connection, connectionSessionID == sessionID {
                if await current.isReady, connection === current {
                    return current
                }
            }
            if let task = connectTask {
                if connectTaskSessionID == sessionID {
                    return try await task.value
                }
                _ = try? await task.value
                continue
            }

            let task = Task(name: "OpenAI realtime connect") {
                try await self.connect(sessionID: sessionID)
            }
            connectTask = task
            connectTaskSessionID = sessionID
            do {
                let realtime = try await task.value
                clearConnectTask(task)
                return realtime
            } catch {
                clearConnectTask(task)
                throw error
            }
        }
    }

    private func clearConnectTask(_ task: Task<OpenAIRealtimeSession, any Error>) {
        if connectTask == task {
            connectTask = nil
            connectTaskSessionID = nil
        }
    }

    private func connect(sessionID: String) async throws -> OpenAIRealtimeSession {
        if let previous = connection {
            let servedAnotherSession = connectionSessionID != sessionID
            connection = nil
            connectionSessionID = nil
            connectionFingerprint = nil
            forwardingTask?.cancel()
            forwardingTask = nil
            if servedAnotherSession {
                // The subscriber belongs to the retired session's surface.
                voiceSubscriber?.finish()
                voiceSubscriber = nil
            }
            await previous.close()
        }
        guard let session = sessions[sessionID] else {
            throw RemoteGenerationClientError.missingSession
        }
        guard let url = webSocketURLOverride
            ?? OpenAIRealtimeModel.webSocketURL(baseURL: provider.baseURL, modelID: provider.modelID) else {
            throw OpenAIRealtimeSessionError.invalidEndpoint(provider.baseURL)
        }
        let settings = await connectionSettings(for: session)
        guard !isShutdown else {
            throw CancellationError()
        }

        let realtime = OpenAIRealtimeSession(transport: transport, url: url, apiKey: apiKey)
        connection = realtime
        connectionSessionID = sessionID
        startForwarding(from: realtime)
        if hasConnectedBefore {
            pendingDiagnostics.append(Self.restartDiagnostic)
        }
        if settings.estimatedTokens > Self.configurationTokenWarningThreshold {
            pendingDiagnostics.append(Self.configurationBudgetDiagnostic)
        }

        do {
            try await realtime.start(instructions: settings.instructions, tools: settings.tools)
        } catch {
            if connection === realtime {
                connection = nil
                connectionSessionID = nil
            }
            await realtime.close()
            throw error
        }
        guard connection === realtime, !isShutdown else {
            await realtime.close()
            throw CancellationError()
        }
        hasConnectedBefore = true
        connectionFingerprint = settings.fingerprint
        toolCatalog = settings.catalog
        return realtime
    }

    private func startForwarding(from realtime: OpenAIRealtimeSession) {
        forwardingTask?.cancel()
        let events = realtime.voiceEvents
        forwardingTask = Task(name: "OpenAI realtime voice forwarding") { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await self.forwardVoiceEvent(event, from: realtime)
            }
        }
    }

    private func retireConnection(finishingSubscriber: Bool) async {
        let current = connection
        connection = nil
        connectionSessionID = nil
        connectionFingerprint = nil
        connectTask?.cancel()
        connectTask = nil
        connectTaskSessionID = nil
        forwardingTask?.cancel()
        forwardingTask = nil
        if finishingSubscriber {
            voiceSubscriber?.finish()
            voiceSubscriber = nil
        }
        if let current {
            await current.close()
        }
    }

    private func scheduleConfigurationSync(sessionID: String) {
        guard connection != nil, connectionSessionID == sessionID else {
            return
        }
        Task(name: "OpenAI realtime configuration sync") {
            try? await self.syncConfigurationIfNeeded(sessionID: sessionID)
        }
    }

    /// Sends `session.update` only when the instructions or tools changed.
    private func syncConfigurationIfNeeded(sessionID: String) async throws {
        guard let realtime = connection,
              connectionSessionID == sessionID,
              let session = sessions[sessionID] else {
            return
        }
        let settings = await connectionSettings(for: session)
        guard connection === realtime,
              settings.fingerprint != connectionFingerprint,
              await realtime.isReady else {
            return
        }
        connectionFingerprint = settings.fingerprint
        toolCatalog = settings.catalog
        try await realtime.updateSession(instructions: settings.instructions, tools: settings.tools)
        if settings.estimatedTokens > Self.configurationTokenWarningThreshold {
            pendingDiagnostics.append(Self.configurationBudgetDiagnostic)
        }
    }

    private func connectionSettings(for session: SessionState) async -> ConnectionSettings {
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
        let catalog = RemoteToolWireCatalog(descriptors: descriptors)
        let tools = catalog.responsesToolPayloads.map { JSONValue(jsonObject: $0) }
        let instructions = Self.instructions(for: session)
        let toolsJSON = JSONValue.array(tools).compactString(sortedKeys: true)
        return ConnectionSettings(
            instructions: instructions,
            tools: tools,
            catalog: catalog,
            fingerprint: instructions + "\u{0}" + toolsJSON,
            estimatedTokens: (instructions.count + toolsJSON.count) / 4
        )
    }

    static func instructions(for session: SessionState) -> String {
        let systemPrompt = session.systemPrompt?.nilIfBlank
            ?? RemoteGenerationClient.systemPrompt(
                cwd: session.cwd.path,
                allowedToolNames: session.allowedToolNames
            )
        return [
            voicePreamble,
            systemPrompt,
            session.dynamicContext?.nilIfBlank.map { AgentRuntimeDynamicContext.marker + $0 }
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: "\n\n")
    }

    private func flushDiagnostics(
        _ onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let diagnostics = pendingDiagnostics
        pendingDiagnostics.removeAll()
        for diagnostic in diagnostics {
            await onEvent(.diagnostic(diagnostic))
        }
    }
}
