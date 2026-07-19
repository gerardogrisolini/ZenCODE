//
//  ChatGPTSubscriptionWebSocketTask.swift
//  ZenCODE
//

#if os(macOS)
import Foundation
import Network
import Synchronization

protocol ChatGPTSubscriptionWebSocketTask: AnyObject, Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var state: URLSessionTask.State { get }

    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(
        pongReceiveHandler: @escaping @Sendable (Error?) -> Void
    )
    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    )
}

extension URLSessionWebSocketTask: ChatGPTSubscriptionWebSocketTask {}

final class ChatGPTSubscriptionNetworkWebSocketTask:
    ChatGPTSubscriptionWebSocketTask,
    @unchecked Sendable {
    private enum Lifecycle {
        case suspended
        case connecting
        case ready
        case failed(Error)
        case cancelled
    }

    private struct State {
        var lifecycle: Lifecycle = .suspended
        var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
        var readinessWaiters: [CheckedContinuation<Void, Error>] = []
    }

    private struct Frame: Sendable {
        let data: Data
        let opcode: NWProtocolWebSocket.Opcode
        let closeCode: NWProtocolWebSocket.CloseCode?
    }

    private enum TransportError: LocalizedError {
        case closed
        case invalidTextFrame

        var errorDescription: String? {
            switch self {
            case .closed:
                return "The ChatGPT Subscription WebSocket is closed."
            case .invalidTextFrame:
                return "The ChatGPT Subscription WebSocket returned invalid UTF-8 text."
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "com.zencode.chatgpt-subscription.websocket"
    )
    private let stateStorage = Mutex(State())

    init(request: URLRequest) {
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = 16 * 1_024 * 1_024
        webSocketOptions.setAdditionalHeaders(
            (request.allHTTPHeaderFields ?? [:])
                .sorted {
                    $0.key.localizedCaseInsensitiveCompare($1.key)
                        == .orderedAscending
                }
                .map { (name: $0.key, value: $0.value) }
        )

        let parameters = NWParameters(
            tls: NWProtocolTLS.Options(),
            tcp: NWProtocolTCP.Options()
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(
            webSocketOptions,
            at: 0
        )
        connection = NWConnection(
            to: .url(request.url!),
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        stateStorage.withLock(\.closeCode)
    }

    var state: URLSessionTask.State {
        stateStorage.withLock { state in
            switch state.lifecycle {
            case .suspended:
                return .suspended
            case .connecting, .ready:
                return .running
            case .failed, .cancelled:
                return .completed
            }
        }
    }

    func resume() {
        let shouldStart = stateStorage.withLock { state -> Bool in
            guard case .suspended = state.lifecycle else {
                return false
            }
            state.lifecycle = .connecting
            return true
        }
        if shouldStart {
            connection.start(queue: queue)
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await waitUntilReady()
        let content: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch message {
        case let .string(text):
            content = Data(text.utf8)
            opcode = .text
        case let .data(data):
            content = data
            opcode = .binary
        @unknown default:
            throw ChatGPTSubscriptionGenerationError.invalidResponse
        }
        try await send(content: content, opcode: opcode)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await waitUntilReady()
        while true {
            let frame = try await receiveFrame()
            switch frame.opcode {
            case .text:
                guard let text = String(data: frame.data, encoding: .utf8) else {
                    throw TransportError.invalidTextFrame
                }
                return .string(text)
            case .binary:
                return .data(frame.data)
            case .ping, .pong, .cont:
                continue
            case .close:
                setCloseCode(frame.closeCode)
                throw TransportError.closed
            @unknown default:
                continue
            }
        }
    }

    func sendPing(
        pongReceiveHandler: @escaping @Sendable (Error?) -> Void
    ) {
        Task { [weak self] in
            guard let self else {
                pongReceiveHandler(TransportError.closed)
                return
            }
            do {
                try await waitUntilReady()
                let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                metadata.setPongHandler(queue) { error in
                    pongReceiveHandler(error)
                }
                let context = NWConnection.ContentContext(
                    identifier: "chatgpt-subscription-ping",
                    metadata: [metadata]
                )
                connection.send(
                    content: nil,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            pongReceiveHandler(error)
                        }
                    }
                )
            } catch {
                pongReceiveHandler(error)
            }
        }
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let waiters = stateStorage.withLock {
            state -> [CheckedContinuation<Void, Error>] in
            guard case .cancelled = state.lifecycle else {
                state.lifecycle = .cancelled
                state.closeCode = closeCode
                return state.readinessWaiters.takeAll()
            }
            return []
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
        connection.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let result = stateStorage.withLock {
                state -> Result<Void, Error>? in
                switch state.lifecycle {
                case .ready:
                    return .success(())
                case let .failed(error):
                    return .failure(error)
                case .cancelled:
                    return .failure(CancellationError())
                case .suspended, .connecting:
                    state.readinessWaiters.append(continuation)
                    return nil
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    private func send(
        content: Data,
        opcode: NWProtocolWebSocket.Opcode
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(
                identifier: "chatgpt-subscription-frame",
                metadata: [metadata]
            )
            connection.send(
                content: content,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receiveFrame() async throws -> Frame {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Frame, Error>) in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata else {
                    continuation.resume(throwing: TransportError.closed)
                    return
                }
                continuation.resume(
                    returning: Frame(
                        data: data ?? Data(),
                        opcode: metadata.opcode,
                        closeCode: metadata.closeCode
                    )
                )
            }
        }
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        let result: Result<Void, Error>
        switch connectionState {
        case .ready:
            result = .success(())
        case let .failed(error):
            result = .failure(error)
        case .cancelled:
            result = .failure(CancellationError())
        default:
            return
        }

        let waiters = stateStorage.withLock {
            state -> [CheckedContinuation<Void, Error>] in
            switch result {
            case .success:
                state.lifecycle = .ready
            case let .failure(error):
                state.lifecycle = error is CancellationError
                    ? .cancelled
                    : .failed(error)
                if state.closeCode == .invalid {
                    state.closeCode = .abnormalClosure
                }
            }
            return state.readinessWaiters.takeAll()
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func setCloseCode(_ closeCode: NWProtocolWebSocket.CloseCode?) {
        guard let closeCode else {
            return
        }
        let rawValue: UInt16
        switch closeCode {
        case let .protocolCode(code):
            rawValue = code.rawValue
        case let .applicationCode(code), let .privateCode(code):
            rawValue = code
        @unknown default:
            return
        }
        stateStorage.withLock { state in
            state.closeCode = URLSessionWebSocketTask.CloseCode(
                rawValue: Int(rawValue)
            ) ?? .invalid
        }
    }
}

private extension Array {
    mutating func takeAll() -> [Element] {
        defer { removeAll(keepingCapacity: true) }
        return self
    }
}
#endif
