//
//  RemoteStreamBytes.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(FoundationNetworking)
public typealias RemoteStreamBytes = AsyncThrowingStream<UInt8, Error>

/// Supplies the streaming API that FoundationNetworking does not expose as
/// `URLSession.bytes(for:)` on Linux.
enum RemoteFoundationNetworkingStream {
    private static let registry = RemoteFoundationNetworkingStreamRegistry()

    static func open(
        for request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (bytes: RemoteStreamBytes, response: URLResponse) {
        let pair = RemoteStreamBytes.makeStream()
        let session = registry.session(for: configuration)
        return try await session.open(
            request: request,
            stream: pair.stream,
            streamContinuation: pair.continuation
        )
    }
}

/// `swift-corelibs-foundation` currently crashes while destroying short-lived
/// HTTPS `URLSession` instances because libcurl can invoke `_MultiHandle`
/// callbacks from inside its deinitializer. Keep one session alive for each
/// effective configuration and multiplex its data tasks instead of creating a
/// session for every streamed response.
private final class RemoteFoundationNetworkingStreamRegistry:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var sessions:
        [ConfigurationKey: RemoteFoundationNetworkingStreamSession] = [:]

    func session(
        for configuration: URLSessionConfiguration
    ) -> RemoteFoundationNetworkingStreamSession {
        let key = ConfigurationKey(configuration)
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] {
            return session
        }
        let session = RemoteFoundationNetworkingStreamSession(
            configuration: configuration
        )
        sessions[key] = session
        return session
    }

    private struct ConfigurationKey: Hashable {
        let value: String

        init(_ configuration: URLSessionConfiguration) {
            let headers = (configuration.httpAdditionalHeaders ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n")
            let proxies = (configuration.connectionProxyDictionary ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n")
            let protocolClasses = (configuration.protocolClasses ?? [])
                .map { NSStringFromClass($0) }
                .sorted()
                .joined(separator: "\n")
            value = [
                String(configuration.timeoutIntervalForRequest),
                String(configuration.timeoutIntervalForResource),
                String(describing: configuration.requestCachePolicy),
                String(configuration.httpMaximumConnectionsPerHost),
                String(configuration.allowsCellularAccess),
                String(configuration.httpShouldSetCookies),
                headers,
                proxies,
                protocolClasses
            ].joined(separator: "\0")
        }
    }
}

private final class RemoteFoundationNetworkingStreamSession:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sessionConfiguration: URLSessionConfiguration
    private var requests: [Int: RequestState] = [:]
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: nil
    )

    init(configuration: URLSessionConfiguration) {
        sessionConfiguration = configuration
    }

    func open(
        request: URLRequest,
        stream: RemoteStreamBytes,
        streamContinuation: RemoteStreamBytes.Continuation
    ) async throws -> (bytes: RemoteStreamBytes, response: URLResponse) {
        let dataTask = session.dataTask(with: request)
        let requestState = RequestState(
            dataTask: dataTask,
            streamContinuation: streamContinuation
        )
        let taskIdentifier = dataTask.taskIdentifier
        store(requestState, for: taskIdentifier)

        streamContinuation.onTermination = { @Sendable [weak self] _ in
            self?.cancel(taskIdentifier: taskIdentifier)
        }

        let response = try await withTaskCancellationHandler {
            try await requestState.waitForResponse()
        } onCancel: {
            self.cancel(taskIdentifier: taskIdentifier)
        }
        return (stream, response)
    }

    private func store(_ requestState: RequestState, for taskIdentifier: Int) {
        lock.lock()
        requests[taskIdentifier] = requestState
        lock.unlock()
    }

    private func requestState(for taskIdentifier: Int) -> RequestState? {
        lock.lock()
        let requestState = requests[taskIdentifier]
        lock.unlock()
        return requestState
    }

    private func removeRequestState(for taskIdentifier: Int) -> RequestState? {
        lock.lock()
        let requestState = requests.removeValue(forKey: taskIdentifier)
        lock.unlock()
        return requestState
    }

    private func cancel(taskIdentifier: Int) {
        removeRequestState(for: taskIdentifier)?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let requestState = requestState(
            for: dataTask.taskIdentifier
        ) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(
            requestState.receive(response: response) ? .allow : .cancel
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        requestState(for: dataTask.taskIdentifier)?.receive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        removeRequestState(for: task.taskIdentifier)?.complete(error: error)
    }

    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private let dataTask: URLSessionDataTask
        private let streamContinuation: RemoteStreamBytes.Continuation
        private var responseContinuation: CheckedContinuation<URLResponse, Error>?
        private var didComplete = false

        init(
            dataTask: URLSessionDataTask,
            streamContinuation: RemoteStreamBytes.Continuation
        ) {
            self.dataTask = dataTask
            self.streamContinuation = streamContinuation
        }

        func waitForResponse() async throws -> URLResponse {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !didComplete, !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                responseContinuation = continuation
                lock.unlock()
                dataTask.resume()
            }
        }

        func receive(response: URLResponse) -> Bool {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return false
            }
            let responseContinuation = responseContinuation
            self.responseContinuation = nil
            lock.unlock()

            responseContinuation?.resume(returning: response)
            return true
        }

        func receive(data: Data) {
            lock.lock()
            let shouldYield = !didComplete
            lock.unlock()
            guard shouldYield else {
                return
            }
            for byte in data {
                streamContinuation.yield(byte)
            }
        }

        func cancel() {
            finish(error: CancellationError(), cancelTask: true)
        }

        func complete(error: Error?) {
            finish(error: error, cancelTask: false)
        }

        private func finish(error: Error?, cancelTask: Bool) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            let responseContinuation = responseContinuation
            self.responseContinuation = nil
            lock.unlock()

            if cancelTask {
                dataTask.cancel()
            }
            if let error {
                responseContinuation?.resume(throwing: error)
                streamContinuation.finish(throwing: error)
            } else if let responseContinuation {
                let responseError = URLError(.badServerResponse)
                responseContinuation.resume(throwing: responseError)
                streamContinuation.finish(throwing: responseError)
            } else {
                streamContinuation.finish()
            }
        }
    }
}
#else
public typealias RemoteStreamBytes = URLSession.AsyncBytes
#endif

struct RemoteStreamLineSequence: AsyncSequence {
    typealias Element = String

    let bytes: RemoteStreamBytes

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(byteIterator: bytes.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var byteIterator: RemoteStreamBytes.AsyncIterator
        var bufferedBytes: [UInt8] = []
        var reachedEnd = false

        mutating func next() async throws -> String? {
            guard !reachedEnd else {
                return nil
            }

            while let byte = try await byteIterator.next() {
                if byte == 0x0A {
                    if bufferedBytes.last == 0x0D {
                        bufferedBytes.removeLast()
                    }
                    let line = String(decoding: bufferedBytes, as: UTF8.self)
                    bufferedBytes.removeAll(keepingCapacity: true)
                    return line
                }
                bufferedBytes.append(byte)
            }

            reachedEnd = true
            guard !bufferedBytes.isEmpty else {
                return nil
            }
            if bufferedBytes.last == 0x0D {
                bufferedBytes.removeLast()
            }
            return String(decoding: bufferedBytes, as: UTF8.self)
        }
    }
}
