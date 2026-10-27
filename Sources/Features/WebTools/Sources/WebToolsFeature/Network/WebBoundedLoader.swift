//  Bounded, policy-guarded HTTP loader shared by web.fetch (raw path) and web.search.

import Dispatch
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of a bounded load: the body is cut at the byte limit, the task is
/// cancelled as soon as the limit is exceeded so the remainder is never
/// downloaded, and `wasTruncated` tells the caller that bytes were dropped.
struct WebBoundedResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
    let wasTruncated: Bool

    /// Declared `Content-Length`, when the server sent one.
    var expectedContentLength: Int64? {
        response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }
}

/// Session delegate that streams the body with `URLSessionDataDelegate`,
/// enforces the byte limit while bytes arrive, applies the redirect policy of
/// ``WebRedirectGuard`` and turns task completion into a single async result.
///
/// One delegate serves one session; every task in that session has its own
/// accumulator keyed by `taskIdentifier`, so a session can be reused for
/// several sequential or parallel loads.
final class WebBoundedLoaderDelegate: WebRedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    private struct Accumulator: Sendable {
        let limit: Int
        var data = Data()
        var response: HTTPURLResponse?
        var wasTruncated = false
        let box = WebSingleResumeBox<WebBoundedResponse>()
    }

    private let accumulators = Mutex<[Int: Accumulator]>([:])

    /// Registers the limit and awaitable box for a task before it resumes.
    func register(task: URLSessionTask, limit: Int) -> WebSingleResumeBox<WebBoundedResponse> {
        let accumulator = Accumulator(limit: limit)
        accumulators.withLock { $0[task.taskIdentifier] = accumulator }
        return accumulator.box
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(dataTask, with: .failure(WebToolsFeatureError.permissionDenied("The web response was not an HTTP response.")))
            completionHandler(.cancel)
            return
        }
        // A declared `Content-Length` above the limit is not refused here: the
        // body is cut at the limit in `didReceive data` exactly like a chunked
        // body, so callers can report `<truncated: N bytes omitted>` using the
        // declared length instead of failing on ordinary large pages.
        accumulators.withLock { state in
            state[dataTask.taskIdentifier]?.response = httpResponse
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = accumulators.withLock { state -> Bool in
            guard var accumulator = state[dataTask.taskIdentifier] else { return false }
            let remaining = accumulator.limit - accumulator.data.count
            if data.count > remaining {
                accumulator.data.append(data.prefix(max(remaining, 0)))
                accumulator.wasTruncated = true
            } else {
                accumulator.data.append(data)
            }
            state[dataTask.taskIdentifier] = accumulator
            return accumulator.wasTruncated
        }
        if exceeded {
            // Resolve with the truncated prefix and stop downloading; the
            // cancellation error that follows is ignored by the single-resume box.
            if let result = snapshotIfComplete(of: dataTask) {
                finish(dataTask, with: .success(result))
            }
            dataTask.cancel()
        }
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let blocked = blockedRedirectError(for: task) {
                finish(task, with: .failure(blocked))
            } else {
                finish(task, with: .failure(error))
            }
            return
        }
        if let blocked = blockedRedirectError(for: task) {
            // The redirect was refused, so URLSession handed us the 3xx itself.
            let location = accumulators.withLock { $0[task.taskIdentifier]?.response?.value(forHTTPHeaderField: "Location") } ?? ""
            finish(task, with: .failure(WebNetworkGuardError.blockedRedirect(
                WebNetworkURLRedaction.apply(to: location),
                underlying: blocked.localizedDescription
            )))
            return
        }
        guard let result = snapshotIfComplete(of: task) else {
            finish(task, with: .failure(WebToolsFeatureError.permissionDenied("The web response was not an HTTP response.")))
            return
        }
        finish(task, with: .success(result))
    }

    private func snapshotIfComplete(of task: URLSessionTask) -> WebBoundedResponse? {
        accumulators.withLock { state in
            guard let accumulator = state[task.taskIdentifier], let response = accumulator.response else { return nil }
            return WebBoundedResponse(data: accumulator.data, response: response, wasTruncated: accumulator.wasTruncated)
        }
    }

    private func finish(_ task: URLSessionTask, with result: Result<WebBoundedResponse, Error>) {
        let box = accumulators.withLock { $0.removeValue(forKey: task.taskIdentifier)?.box }
        box?.resume(with: result)
    }
}

extension WebToolsSupport {
    /// A URLSession whose redirect handling and body size are guarded.
    /// Each hop (including the very first request, validated by the caller)
    /// is re-checked against URL restrictions and resolved addresses, so DNS
    /// rebinding and redirect chains into private networks are both rejected.
    /// `timeout` bounds the whole transfer, not only connection idle time.
    static func makeBoundedSession(policy: WebNetworkRequestPolicy, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
#if canImport(Darwin)
        configuration.waitsForConnectivity = false
#endif
        return URLSession(
            configuration: configuration,
            delegate: WebBoundedLoaderDelegate(policy: policy),
            delegateQueue: nil
        )
    }

    /// Performs one GET on a session made by ``makeBoundedSession(policy:timeout:)``,
    /// never buffering more than `maxBytes` of body. Cancelling the calling
    /// task cancels the transfer.
    static func loadBounded(_ request: URLRequest, session: URLSession, maxBytes: Int) async throws -> WebBoundedResponse {
        guard let delegate = session.delegate as? WebBoundedLoaderDelegate else {
            preconditionFailure("loadBounded requires a session created by makeBoundedSession")
        }
        let task = session.dataTask(with: request)
        let box = delegate.register(task: task, limit: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebBoundedResponse, Error>) in
                box.attach(continuation)
                task.resume()
            }
        } onCancel: {
            box.resume(throwing: CancellationError())
            task.cancel()
        }
    }
}
