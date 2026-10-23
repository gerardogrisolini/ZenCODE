//
//  OpenAIRealtimeSession.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation
import ToolCore

/// Voice-surface events published by one realtime connection.
///
/// Audio is delivered as raw little-endian PCM16 mono at 24 kHz. It is only
/// ever handed to the presentation layer for playback and is never persisted.
public enum OpenAIRealtimeVoiceEvent: Sendable, Equatable {
    case connected
    case disconnected(String)
    case speechStarted
    case speechStopped
    case turnCommitted(itemID: String)
    case audio(Data, itemID: String, responseID: String)
    case interruptPlayback
}

/// Typed realtime failures. Provider failures carry only the provider's code
/// and message, never a raw event payload.
public enum OpenAIRealtimeSessionError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case notConnected
    case connectionTimedOut
    case disconnected(String)
    case provider(code: String?, message: String)
    case responseAlreadyActive
    case noPendingResponse

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(baseURL):
            return "Cannot derive a realtime WebSocket endpoint from \(baseURL)."
        case .notConnected:
            return "The realtime voice session is not connected."
        case .connectionTimedOut:
            return "The realtime voice session did not become ready in time."
        case let .disconnected(reason):
            return "The realtime voice session disconnected: \(reason)"
        case let .provider(code, message):
            if let code {
                return "Realtime provider error \(code): \(message)"
            }
            return "Realtime provider error: \(message)"
        case .responseAlreadyActive:
            return "A realtime response is already in progress."
        case .noPendingResponse:
            return "No realtime response is pending."
        }
    }
}

struct OpenAIRealtimeFunctionCall: Sendable, Equatable {
    let callID: String
    let name: String
    let argumentsJSON: String
}

struct OpenAIRealtimeResponseResult: Sendable, Equatable {
    let responseID: String?
    /// Provider status: `completed`, `cancelled`, `failed` or `incomplete`.
    let status: String
    let functionCalls: [OpenAIRealtimeFunctionCall]
    let transcript: String
    let failure: OpenAIRealtimeSessionError?

    func replacingTranscript(_ transcript: String) -> OpenAIRealtimeResponseResult {
        OpenAIRealtimeResponseResult(
            responseID: responseID,
            status: status,
            functionCalls: functionCalls,
            transcript: transcript,
            failure: failure
        )
    }
}

/// One OpenAI Realtime WebSocket conversation.
///
/// The actor owns the socket, the single in-flight response and the barge-in
/// bookkeeping. It is platform neutral: audio capture and playback live in the
/// presentation layer, which feeds PCM16 through `appendInputAudio` and
/// reports playback progress through `reportPlayback`.
///
/// Every outgoing frame is written from an unstructured task. The shared
/// WebSocket driver closes the connection when a *cancelled* caller sends, and a
/// cancelled prompt turn must still be able to cancel its response without
/// tearing down the whole voice conversation.
actor OpenAIRealtimeSession {
    enum State: Sendable, Equatable {
        case idle
        case connecting
        case ready
        case disconnected(String)
    }

    private enum ResponseSignal: Sendable {
        case transcriptDelta(String)
        case done(OpenAIRealtimeResponseResult)
        case failed(OpenAIRealtimeSessionError)
    }

    static let sampleRate = 24_000
    /// PCM16 mono at 24 kHz: 24 samples per millisecond, two bytes each.
    static let bytesPerMillisecond = 48
    static let defaultVoice = "marin"
    static let benignErrorCodes: Set<String> = ["response_cancel_not_active"]
    private static let maximumTrackedBenignEventIDs = 64
    private static let responseIdleTimeout = Duration.seconds(5)

    nonisolated let voiceEvents: AsyncStream<OpenAIRealtimeVoiceEvent>
    private let voiceContinuation: AsyncStream<OpenAIRealtimeVoiceEvent>.Continuation
    private let transport: RemoteTransportCore
    private let url: URL
    private let apiKey: String?
    private let voice: String
    private let readyTimeout: Duration

    private(set) var state: State = .idle
    private var socket: RemoteWebSocketConnection?
    private var readTask: Task<Void, Never>?
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var pendingSessionUpdate: String?
    private var textFragment: Data?
    private var eventSerial = 0
    private var benignEventIDs: Set<String> = []

    private var awaitingResponseCreation = false
    private(set) var activeResponseID: String?
    private var responseSignals: AsyncStream<ResponseSignal>.Continuation?
    private var pendingResponseStream: AsyncStream<ResponseSignal>?
    /// Committed user speech turns not yet answered by a `response.create`.
    private(set) var pendingCommittedTurns = 0

    private var assistantAudioItemID: String?
    private var assistantAudioBytes = 0
    private var assistantPlayedMilliseconds = 0

    init(
        transport: RemoteTransportCore,
        url: URL,
        apiKey: String?,
        voice: String = OpenAIRealtimeSession.defaultVoice,
        readyTimeout: Duration = .seconds(20)
    ) {
        self.transport = transport
        self.url = url
        self.apiKey = apiKey?.nilIfBlank
        self.voice = voice
        self.readyTimeout = readyTimeout
        let (events, continuation) = AsyncStream.makeStream(
            of: OpenAIRealtimeVoiceEvent.self,
            bufferingPolicy: .unbounded
        )
        voiceEvents = events
        voiceContinuation = continuation
    }

    deinit {
        readTask?.cancel()
        responseSignals?.finish()
        voiceContinuation.finish()
    }

    var isReady: Bool {
        state == .ready
    }

    var disconnectReason: String? {
        guard case let .disconnected(reason) = state else {
            return nil
        }
        return reason
    }

    // MARK: - Lifecycle

    /// Connects, configures the conversation on `session.created`, and returns
    /// once the provider acknowledges it with `session.updated`.
    func start(instructions: String, tools: [JSONValue]) async throws {
        switch state {
        case .ready:
            return
        case .connecting:
            throw OpenAIRealtimeSessionError.notConnected
        case let .disconnected(reason):
            throw OpenAIRealtimeSessionError.disconnected(reason)
        case .idle:
            break
        }
        state = .connecting
        do {
            pendingSessionUpdate = try encodedEvent(
                Self.sessionUpdatePayload(instructions: instructions, tools: tools, voice: voice)
            )
            var headers: [RemoteHTTPHeader] = []
            if let apiKey {
                headers.append(RemoteHTTPHeader(name: "Authorization", value: "Bearer \(apiKey)"))
            }
            let socket = try await transport.connectWebSocket(
                RemoteWebSocketRequest(url: url, headers: headers, timeout: .seconds(30))
            )
            guard state == .connecting else {
                try? await socket.close()
                throw OpenAIRealtimeSessionError.disconnected(disconnectReason ?? "Voice session closed.")
            }
            self.socket = socket
            startReading(socket)
            try await waitUntilReady()
        } catch is CancellationError {
            await markDisconnected(reason: "Voice session start was cancelled.")
            throw CancellationError()
        } catch let error as OpenAIRealtimeSessionError {
            await markDisconnected(reason: Self.reason(for: error), error: error)
            throw error
        } catch let error as RemoteTransportError {
            let failure = Self.sessionError(for: error)
            await markDisconnected(reason: Self.reason(for: failure), error: failure)
            throw failure
        } catch {
            let failure = OpenAIRealtimeSessionError.disconnected(error.localizedDescription)
            await markDisconnected(reason: error.localizedDescription, error: failure)
            throw failure
        }
    }

    func close() async {
        await markDisconnected(reason: "Voice session closed.")
    }

    // MARK: - Conversation

    /// Replaces the instructions and tools of a live conversation.
    func updateSession(instructions: String, tools: [JSONValue]) async throws {
        try ensureReady()
        try await sendEvent(
            Self.sessionUpdatePayload(instructions: instructions, tools: tools, voice: voice)
        )
    }

    func createUserTextItem(_ text: String) async throws {
        try ensureReady()
        try await sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ] as [String: Any]
        ])
    }

    func createFunctionCallOutput(callID: String, output: String) async throws {
        try ensureReady()
        try await sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ])
    }

    /// Starts exactly one response. A response that is still being cancelled
    /// is allowed to finish first, so two responses are never active at once.
    func createResponse() async throws {
        try ensureReady()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.responseIdleTimeout)
        while activeResponseID != nil || awaitingResponseCreation {
            guard clock.now < deadline else {
                throw OpenAIRealtimeSessionError.responseAlreadyActive
            }
            try await Task.sleep(for: .milliseconds(20))
            try ensureReady()
        }
        pendingCommittedTurns = 0
        awaitingResponseCreation = true
        let (stream, continuation) = AsyncStream.makeStream(
            of: ResponseSignal.self,
            bufferingPolicy: .unbounded
        )
        responseSignals?.finish()
        responseSignals = continuation
        pendingResponseStream = stream
        do {
            try await sendEvent(["type": "response.create"])
        } catch {
            awaitingResponseCreation = false
            pendingResponseStream = nil
            responseSignals?.finish()
            responseSignals = nil
            throw error
        }
    }

    /// Waits for the response started by the last `createResponse()`,
    /// forwarding its audio transcript as it streams.
    func awaitResponseDone(
        onTranscriptDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> OpenAIRealtimeResponseResult {
        guard let stream = pendingResponseStream else {
            throw OpenAIRealtimeSessionError.noPendingResponse
        }
        pendingResponseStream = nil
        var transcript = ""
        for await signal in stream {
            switch signal {
            case let .transcriptDelta(delta):
                transcript += delta
                await onTranscriptDelta(delta)
            case let .done(result):
                return transcript.isEmpty ? result : result.replacingTranscript(transcript)
            case let .failed(error):
                throw error
            }
        }
        try Task.checkCancellation()
        throw OpenAIRealtimeSessionError.disconnected(disconnectReason ?? "Voice session closed.")
    }

    /// Cancels the in-flight response, if any. A provider reply that no
    /// response was active is expected and ignored.
    func cancelActiveResponse() async {
        guard state == .ready, activeResponseID != nil || awaitingResponseCreation else {
            return
        }
        var payload: [String: Any] = ["type": "response.cancel"]
        if let activeResponseID {
            payload["response_id"] = activeResponseID
        }
        try? await sendEvent(payload, benign: true)
    }

    // MARK: - Audio

    func appendInputAudio(_ pcm16: Data) async {
        guard state == .ready, !pcm16.isEmpty else {
            return
        }
        try? await sendEvent(
            ["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()],
            includeEventID: false
        )
    }

    /// Records how much of an assistant audio item was actually played.
    func reportPlayback(itemID: String, playedMilliseconds: Int) {
        guard itemID == assistantAudioItemID else {
            return
        }
        assistantPlayedMilliseconds = max(assistantPlayedMilliseconds, playedMilliseconds)
    }

    // MARK: - Inbound events

    private func startReading(_ socket: RemoteWebSocketConnection) {
        readTask = Task(name: "OpenAI realtime read loop") { [weak self] in
            var reason = "The provider closed the voice session."
            do {
                while let frame = try await socket.receive() {
                    guard let self else {
                        return
                    }
                    await self.handle(frame)
                }
            } catch is CancellationError {
                reason = "Voice session closed."
            } catch {
                reason = error.localizedDescription
            }
            await self?.markDisconnected(reason: reason)
        }
    }

    private func handle(_ frame: RemoteWebSocketFrame) async {
        switch frame {
        case let .text(text, final):
            if final {
                textFragment = nil
                await handleMessage(text)
            } else {
                textFragment = Data(text.utf8)
            }
        case let .continuation(data, final):
            guard textFragment != nil else {
                return
            }
            textFragment?.append(data)
            if final, let fragment = textFragment {
                textFragment = nil
                await handleMessage(String(decoding: fragment, as: UTF8.self))
            }
        case let .close(code, reason):
            let detail = reason?.nilIfBlank ?? code.map { "close code \($0)" } ?? "connection closed"
            await markDisconnected(reason: "The provider closed the voice session (\(detail)).")
        case .binary, .ping, .pong:
            return
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            guard let update = pendingSessionUpdate else {
                return
            }
            pendingSessionUpdate = nil
            do {
                try await sendText(update)
            } catch {
                await markDisconnected(reason: error.localizedDescription)
            }
        case "session.updated":
            guard state == .connecting else {
                return
            }
            state = .ready
            resumeReadyWaiter(throwing: nil)
            voiceContinuation.yield(.connected)
        case "input_audio_buffer.speech_started":
            voiceContinuation.yield(.speechStarted)
            voiceContinuation.yield(.interruptPlayback)
            await truncateUnplayedAssistantAudio()
        case "input_audio_buffer.speech_stopped":
            voiceContinuation.yield(.speechStopped)
        case "input_audio_buffer.committed":
            pendingCommittedTurns += 1
            voiceContinuation.yield(.turnCommitted(itemID: event["item_id"] as? String ?? ""))
        case "response.created":
            let response = event["response"] as? [String: Any]
            activeResponseID = response?["id"] as? String ?? activeResponseID
            awaitingResponseCreation = false
        case "response.output_audio.delta", "response.audio.delta":
            handleAudioDelta(event)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = event["delta"] as? String,
                  !delta.isEmpty,
                  isCurrentResponse(event["response_id"] as? String) else {
                return
            }
            responseSignals?.yield(.transcriptDelta(delta))
        case "response.done":
            handleResponseDone(event["response"] as? [String: Any] ?? [:])
        case "error":
            await handleProviderError(event["error"] as? [String: Any] ?? [:])
        default:
            return
        }
    }

    private func isCurrentResponse(_ responseID: String?) -> Bool {
        guard let responseID, let activeResponseID else {
            return true
        }
        return responseID == activeResponseID
    }

    private func handleAudioDelta(_ event: [String: Any]) {
        guard let encoded = event["delta"] as? String,
              let audio = Data(base64Encoded: encoded),
              !audio.isEmpty else {
            return
        }
        let itemID = event["item_id"] as? String ?? ""
        let responseID = event["response_id"] as? String ?? activeResponseID ?? ""
        if assistantAudioItemID != itemID {
            assistantAudioItemID = itemID
            assistantAudioBytes = 0
            assistantPlayedMilliseconds = 0
        }
        assistantAudioBytes += audio.count
        voiceContinuation.yield(.audio(audio, itemID: itemID, responseID: responseID))
    }

    /// Barge-in: drops the unheard tail of the last assistant audio item from
    /// the provider-side conversation so the model does not assume the user
    /// heard it.
    private func truncateUnplayedAssistantAudio() async {
        guard let itemID = assistantAudioItemID, !itemID.isEmpty else {
            return
        }
        let receivedMilliseconds = assistantAudioBytes / Self.bytesPerMillisecond
        let playedMilliseconds = min(assistantPlayedMilliseconds, receivedMilliseconds)
        assistantAudioItemID = nil
        assistantAudioBytes = 0
        assistantPlayedMilliseconds = 0
        guard playedMilliseconds < receivedMilliseconds else {
            return
        }
        try? await sendEvent(
            [
                "type": "conversation.item.truncate",
                "item_id": itemID,
                "content_index": 0,
                "audio_end_ms": playedMilliseconds
            ],
            benign: true
        )
    }

    private func handleResponseDone(_ response: [String: Any]) {
        guard awaitingResponseCreation || activeResponseID != nil else {
            return
        }
        if let responseID = response["id"] as? String,
           let activeResponseID,
           responseID != activeResponseID {
            return
        }
        activeResponseID = nil
        awaitingResponseCreation = false
        responseSignals?.yield(.done(Self.responseResult(from: response)))
        responseSignals?.finish()
        responseSignals = nil
    }

    private func handleProviderError(_ error: [String: Any]) async {
        if let eventID = error["event_id"] as? String,
           benignEventIDs.remove(eventID) != nil {
            return
        }
        let code = (error["code"] as? String)?.nilIfBlank
        if let code, Self.benignErrorCodes.contains(code) {
            return
        }
        let message = (error["message"] as? String)?.nilIfBlank
            ?? "Unknown realtime provider error."
        let failure = OpenAIRealtimeSessionError.provider(code: code, message: message)
        await markDisconnected(reason: Self.reason(for: failure), error: failure)
    }

    // MARK: - State transitions

    private func markDisconnected(
        reason: String,
        error: OpenAIRealtimeSessionError? = nil
    ) async {
        if case .disconnected = state {
            return
        }
        state = .disconnected(reason)
        let failure = error ?? .disconnected(reason)
        resumeReadyWaiter(throwing: failure)
        responseSignals?.yield(.failed(failure))
        responseSignals?.finish()
        responseSignals = nil
        activeResponseID = nil
        awaitingResponseCreation = false
        pendingSessionUpdate = nil
        voiceContinuation.yield(.disconnected(reason))
        voiceContinuation.finish()
        readTask?.cancel()
        readTask = nil
        let socket = self.socket
        self.socket = nil
        if let socket {
            try? await socket.close()
        }
    }

    private func waitUntilReady() async throws {
        if state == .ready {
            return
        }
        let timeout = readyTimeout
        let timeoutTask = Task(name: "OpenAI realtime ready timeout") { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else {
                return
            }
            await self?.readyTimedOut()
        }
        defer {
            timeoutTask.cancel()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                switch state {
                case .ready:
                    continuation.resume()
                case let .disconnected(reason):
                    continuation.resume(throwing: OpenAIRealtimeSessionError.disconnected(reason))
                case .idle, .connecting:
                    readyWaiter = continuation
                }
            }
        } onCancel: {
            Task(name: "OpenAI realtime ready cancellation") {
                await self.resumeReadyWaiter(throwing: CancellationError())
            }
        }
    }

    private func readyTimedOut() async {
        guard readyWaiter != nil else {
            return
        }
        await markDisconnected(
            reason: OpenAIRealtimeSessionError.connectionTimedOut.localizedDescription,
            error: .connectionTimedOut
        )
    }

    private func resumeReadyWaiter(throwing error: (any Error)?) {
        guard let waiter = readyWaiter else {
            return
        }
        readyWaiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    private func ensureReady() throws {
        switch state {
        case .ready:
            return
        case let .disconnected(reason):
            throw OpenAIRealtimeSessionError.disconnected(reason)
        case .idle, .connecting:
            throw OpenAIRealtimeSessionError.notConnected
        }
    }

    // MARK: - Outbound frames

    private func sendEvent(
        _ payload: [String: Any],
        benign: Bool = false,
        includeEventID: Bool = true
    ) async throws {
        var payload = payload
        if includeEventID {
            eventSerial += 1
            let eventID = "zen_evt_\(eventSerial)"
            payload["event_id"] = eventID
            if benign {
                if benignEventIDs.count >= Self.maximumTrackedBenignEventIDs {
                    benignEventIDs.removeAll()
                }
                benignEventIDs.insert(eventID)
            }
        }
        try await sendText(try encodedEvent(payload))
    }

    private func sendText(_ text: String) async throws {
        guard let socket else {
            throw OpenAIRealtimeSessionError.notConnected
        }
        do {
            // Unstructured on purpose: see the type documentation.
            try await Task(name: "OpenAI realtime send") {
                try await socket.send(.text(text))
            }.value
        } catch {
            let reason = error.localizedDescription
            await markDisconnected(reason: reason)
            throw OpenAIRealtimeSessionError.disconnected(reason)
        }
    }

    private func encodedEvent(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Wire payloads

    static func sessionUpdatePayload(
        instructions: String,
        tools: [JSONValue],
        voice: String
    ) -> [String: Any] {
        let pcmFormat: [String: Any] = ["type": "audio/pcm", "rate": sampleRate]
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": instructions,
            "tools": tools.map(\.jsonObject),
            "tool_choice": "auto",
            "audio": [
                "input": [
                    "format": pcmFormat,
                    "turn_detection": [
                        "type": "server_vad",
                        "create_response": false,
                        "interrupt_response": true
                    ] as [String: Any]
                ] as [String: Any],
                "output": [
                    "format": pcmFormat,
                    "voice": voice
                ] as [String: Any]
            ] as [String: Any]
        ]
        return ["type": "session.update", "session": session]
    }

    static func responseResult(from response: [String: Any]) -> OpenAIRealtimeResponseResult {
        let status = (response["status"] as? String)?.nilIfBlank ?? "completed"
        var functionCalls: [OpenAIRealtimeFunctionCall] = []
        var transcript = ""
        for item in response["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "function_call":
                guard let callID = (item["call_id"] as? String)?.nilIfBlank,
                      let name = (item["name"] as? String)?.nilIfBlank else {
                    continue
                }
                functionCalls.append(OpenAIRealtimeFunctionCall(
                    callID: callID,
                    name: name,
                    argumentsJSON: item["arguments"] as? String ?? "{}"
                ))
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if let text = part["transcript"] as? String {
                        transcript += text
                    } else if let text = part["text"] as? String {
                        transcript += text
                    }
                }
            default:
                continue
            }
        }

        var failure: OpenAIRealtimeSessionError?
        if status == "failed" {
            let details = response["status_details"] as? [String: Any]
            let error = details?["error"] as? [String: Any]
            failure = .provider(
                code: (error?["code"] as? String)?.nilIfBlank ?? (error?["type"] as? String)?.nilIfBlank,
                message: (error?["message"] as? String)?.nilIfBlank ?? "The realtime response failed."
            )
        }
        return OpenAIRealtimeResponseResult(
            responseID: response["id"] as? String,
            status: status,
            functionCalls: functionCalls,
            transcript: transcript,
            failure: failure
        )
    }

    /// Maps a transport failure to a typed error. A rejected upgrade surfaces
    /// only the provider's error code and message, never the raw body.
    static func sessionError(for error: RemoteTransportError) -> OpenAIRealtimeSessionError {
        guard case let .upgradeRejected(status, body) = error else {
            return .disconnected(error.localizedDescription)
        }
        if let data = body.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let payload = object["error"] as? [String: Any],
           let message = (payload["message"] as? String)?.nilIfBlank {
            return .provider(
                code: (payload["code"] as? String)?.nilIfBlank ?? (payload["type"] as? String)?.nilIfBlank,
                message: message
            )
        }
        return .provider(
            code: "http_\(status)",
            message: "The provider rejected the realtime connection (HTTP \(status))."
        )
    }

    private static func reason(for error: OpenAIRealtimeSessionError) -> String {
        switch error {
        case let .provider(code, message):
            return [code, message].compactMap { $0 }.joined(separator: ": ")
        case let .disconnected(reason):
            return reason
        default:
            return error.localizedDescription
        }
    }
}
