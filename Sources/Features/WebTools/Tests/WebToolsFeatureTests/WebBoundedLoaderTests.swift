//
//  WebBoundedLoaderTests.swift
//  ZenCODE
//
//  Bounded loader and redirect guard suites of the web tools, with the
//  continuation hooks they share.
//

import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

@Suite
struct WebBoundedLoaderTests {
    private func makeSession() -> URLSession {
        WebToolsSupport.makeBoundedSession(
            policy: WebNetworkRequestPolicy(
                urlPolicy: WebURLPolicy(environment: [:]),
                resolver: StaticWebHostResolver(addressesByHost: ["public.example": ["93.184.216.34"]])
            ),
            timeout: 5
        )
    }

    private func response(status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://public.example/a")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    /// Drives the delegate directly with a never-resumed task, so no bytes
    /// hit the network and the limit logic alone is exercised.
    private func awaitResult(
        of box: FeatureSingleResumeBox<WebBoundedResponse>
    ) async throws -> WebBoundedResponse {
        try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
        }
    }

    @Test
    func bodyIsCutAtTheLimitAndReportedAsTruncated() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 10)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(session, dataTask: task, didReceive: try response(), completionHandler: { disposition.record($0) })
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("0123456".utf8))
        delegate.urlSession(session, dataTask: task, didReceive: Data("789ABCDEF".utf8))
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "0123456789")
        #expect(result.wasTruncated)
        // The cancellation that follows the cut must not disturb the result.
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    /// swift-corelibs-foundation invokes `didCompleteWithError` through the
    /// `URLSessionTaskDelegate` existential. The conformance lives on the
    /// `WebRedirectGuard` base class, so the loader's implementation must be
    /// a real override of a base-class method; a method declared only on the
    /// subclass would be bypassed there and the load would never finish
    /// (Darwin dispatches dynamically and would hide the bug).
    @Test
    func completionIsDeliveredThroughTheTaskDelegateExistential() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(session, dataTask: task, didReceive: try response(), completionHandler: { disposition.record($0) })
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("hello".utf8))
        let taskDelegate: any URLSessionTaskDelegate = delegate
        #if canImport(Darwin)
        taskDelegate.urlSession?(session, task: task, didCompleteWithError: nil)
        #else
        taskDelegate.urlSession(session, task: task, didCompleteWithError: nil)
        #endif
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "hello")
    }

    @Test
    func completeBodyWithinTheLimitIsNotTruncated() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(headers: ["Content-Length": "5"]),
            completionHandler: { disposition.record($0) }
        )
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("hello".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "hello")
        #expect(!result.wasTruncated)
        #expect(result.response.expectedContentLength == 5)
    }

    @Test
    func declaredOversizedBodyIsTruncatedNotRefused() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 10)
        let disposition = ResponseDispositionHook()

        // A 2xx page declaring more bytes than the limit must still be allowed
        // and cut at the limit, so ordinary large pages are previewed with a
        // `<truncated: N bytes omitted>` note instead of failing.
        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(headers: ["Content-Length": "5000"]),
            completionHandler: { disposition.record($0) }
        )
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("0123456789ABCDEF".utf8))
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "0123456789")
        #expect(result.wasTruncated)
        #expect(result.response.expectedContentLength == 5000)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    @Test
    func blockedRedirectIsReportedWithItsPolicyReason() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)

        let redirect = RedirectHookResult()
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: try response(status: 302, headers: ["Location": "http://127.0.0.1:9000/secret"]),
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9000/secret")!),
            completionHandler: { redirect.complete(with: $0) }
        )
        #expect(await redirect.value == nil)
        // URLSession now delivers the 3xx itself and completes without error.
        let disposition = ResponseDispositionHook()
        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(status: 302, headers: ["Location": "http://127.0.0.1:9000/secret"]),
            completionHandler: { disposition.record($0) }
        )
        _ = await disposition.value
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        do {
            _ = try await awaitResult(of: box)
            Issue.record("a blocked redirect must fail the load")
        } catch let error as WebNetworkGuardError {
            guard case let .blockedRedirect(url, underlying) = error else {
                Issue.record("unexpected guard error \(error)")
                return
            }
            #expect(url == "http://127.0.0.1:9000/secret")
            #expect(underlying.contains("127.0.0.1"))
        }
    }

    @Test
    func redirectChainsAreCapped() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: ["public.example": ["93.184.216.34"]])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)

        for hop in 1...(WebRedirectGuard.maximumRedirects + 1) {
            let hook = RedirectHookResult()
            guardDelegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: try response(status: 302, headers: ["Location": "https://public.example/\(hop)"]),
                newRequest: URLRequest(url: URL(string: "https://public.example/\(hop)")!),
                completionHandler: { hook.complete(with: $0) }
            )
            let followed = await hook.value
            if hop <= WebRedirectGuard.maximumRedirects {
                #expect(followed != nil, "hop \(hop) should be followed")
                #expect(guardDelegate.blockedRedirectError(for: task) == nil)
            } else {
                #expect(followed == nil, "hop \(hop) should be refused")
                #expect(guardDelegate.blockedRedirectError(for: task) is WebNetworkGuardError)
            }
        }
    }

    @Test
    func singleResumeBoxIgnoresLaterResults() async throws {
        let box = FeatureSingleResumeBox<Int>()
        box.resume(returning: 1)
        box.resume(returning: 2)
        let first: Int = try await withCheckedThrowingContinuation { box.attach($0) }
        #expect(first == 1)
        box.resume(throwing: CancellationError()) // ignored: already resumed
    }
}

/// Captures the disposition passed to a `didReceive response` hook.
private final class ResponseDispositionHook: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLSession.ResponseDisposition, Never>?
    private var stored: URLSession.ResponseDisposition?

    func record(_ disposition: URLSession.ResponseDisposition) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: disposition)
            return
        }
        stored = disposition
        lock.unlock()
    }

    var value: URLSession.ResponseDisposition {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let stored {
                    self.stored = nil
                    lock.unlock()
                    continuation.resume(returning: stored)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}

@Suite
struct WebRedirectGuardTests {
    @Test
    func redirectGuardAllowsPublicRedirectAndRejectsPrivateRedirect() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [
                "public.example": ["93.184.216.34"],
                "internal.example": ["10.0.0.1"],
            ])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let allowed = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://public.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://public.example/b")!),
            completionHandler: { allowed.complete(with: $0) }
        )
        let allowedRequest = await allowed.value
        #expect(allowedRequest?.url?.absoluteString == "https://public.example/b")
        task.cancel()

        let blockedTask = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)
        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: blockedTask,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://internal.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://internal.example/b")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        blockedTask.cancel()
    }

    @Test
    func redirectGuardRejectsRedirectToLoopbackLiteral() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [:])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 301,
                httpVersion: nil,
                headerFields: ["Location": "http://127.0.0.1:9000/secret"]
            )!,
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9000/secret")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        task.cancel()
    }
}

/// Turns the completion-based redirect hook into a single awaitable value.
private final class RedirectHookResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLRequest?, Never>?
    private var result: Result<URLRequest?, Never>?

    func complete(with request: URLRequest?) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: request)
            return
        }
        result = .success(request)
        lock.unlock()
    }

    var value: URLRequest? {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
                lock.lock()
                if let result {
                    self.result = nil
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}
