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
    static func open(
        for request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (bytes: RemoteStreamBytes, response: URLResponse) {
        let pair = RemoteStreamBytes.makeStream()
        let delegate = RemoteFoundationNetworkingStreamDelegate(
            stream: pair.stream,
            streamContinuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable [weak delegate] _ in
            delegate?.cancel()
        }
        let response = try await delegate.start(
            request: request,
            configuration: configuration
        )
        return (pair.stream, response)
    }
}

private final class RemoteFoundationNetworkingStreamDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let stream: RemoteStreamBytes
    private let streamContinuation: RemoteStreamBytes.Continuation
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var didComplete = false

    init(
        stream: RemoteStreamBytes,
        streamContinuation: RemoteStreamBytes.Continuation
    ) {
        self.stream = stream
        self.streamContinuation = streamContinuation
    }

    func start(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !didComplete, !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                responseContinuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let dataTask = session.dataTask(with: request)
                self.dataTask = dataTask
                lock.unlock()
                dataTask.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let responseContinuation = responseContinuation
        self.responseContinuation = nil
        let dataTask = dataTask
        self.dataTask = nil
        let session = session
        self.session = nil
        lock.unlock()

        responseContinuation?.resume(throwing: CancellationError())
        streamContinuation.finish(throwing: CancellationError())
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let responseContinuation = responseContinuation
        self.responseContinuation = nil
        lock.unlock()

        responseContinuation?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let responseContinuation = responseContinuation
        self.responseContinuation = nil
        self.dataTask = nil
        self.session = nil
        lock.unlock()

        if let error {
            responseContinuation?.resume(throwing: error)
            streamContinuation.finish(throwing: error)
        } else if let responseContinuation {
            let error = URLError(.badServerResponse)
            responseContinuation.resume(throwing: error)
            streamContinuation.finish(throwing: error)
        } else {
            streamContinuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
#else
public typealias RemoteStreamBytes = URLSession.AsyncBytes
#endif
