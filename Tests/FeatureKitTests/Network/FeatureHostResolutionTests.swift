//
//  FeatureHostResolutionTests.swift
//  ZenCODE
//

import Dispatch
import FeatureKit
import Testing

/// Coverage for the policy-free resolution primitives: the system resolver's
/// normalization and RFC 6761 shortcut, the single-resume box, and the
/// cancellation-aware blocking offload. No test depends on external DNS.
@Suite(.timeLimit(.minutes(1)))
struct FeatureHostResolutionTests {
    // MARK: - System resolver

    @Test(arguments: ["localhost", "LOCALHOST", "app.localhost", " localhost. ", "[localhost]", "Dev.LocalHost"])
    func localhostNamesResolveWithoutThePlatformResolver(host: String) throws {
        #expect(try FeatureSystemHostResolver().resolve(host: host) == ["127.0.0.1", "::1"])
    }

    @Test(arguments: ["", "   ", "[]", "...", " [.] "])
    func emptyHostsFailWithTheOriginalHost(host: String) {
        #expect(throws: FeatureHostResolutionError.unresolvedHost(host)) {
            try FeatureSystemHostResolver().resolve(host: host)
        }
    }

    @Test
    func numericHostsResolveToTheirOwnAddress() throws {
        let resolver = FeatureSystemHostResolver()
        #expect(try resolver.resolve(host: "127.0.0.1") == ["127.0.0.1"])
        #expect(try resolver.resolve(host: "[::1]") == ["::1"])
    }

    @Test
    func resolverErrorsAreTypedAndNeutral() {
        do {
            _ = try FeatureSystemHostResolver().resolve(host: " ")
            Issue.record("An empty host must not resolve.")
        } catch {
            // `error` is statically a FeatureHostResolutionError (typed throws).
            switch error {
            case let .unresolvedHost(host):
                #expect(host == " ")
            case .noResolvedAddresses:
                Issue.record("Unexpected error \(error).")
            }
        }
    }

    // MARK: - Single-resume box

    @Test
    func boxDeliversTheFirstResultThatArrivedBeforeAttach() async throws {
        let box = FeatureSingleResumeBox<Int>()
        box.resume(returning: 1)
        box.resume(returning: 2)
        box.resume(throwing: CancellationError())
        let value: Int = try await withCheckedThrowingContinuation { box.attach($0) }
        #expect(value == 1)
        box.resume(returning: 3) // ignored: already resumed
    }

    @Test
    func boxDeliversAnEarlyErrorAndIgnoresLaterValues() async {
        let box = FeatureSingleResumeBox<Int>()
        box.resume(throwing: CancellationError())
        box.resume(returning: 1)
        await #expect(throws: CancellationError.self) {
            let _: Int = try await withCheckedThrowingContinuation { box.attach($0) }
        }
    }

    @Test
    func boxResumesAnAttachedContinuationExactlyOnceUnderContention() async throws {
        for _ in 0..<50 {
            let box = FeatureSingleResumeBox<Int>()
            let value: Int = try await withCheckedThrowingContinuation { continuation in
                box.attach(continuation)
                // A second resume of a CheckedContinuation traps, so surviving
                // the race proves the box resumes exactly once.
                DispatchQueue.concurrentPerform(iterations: 16) { index in
                    box.resume(returning: index)
                }
            }
            #expect((0..<16).contains(value))
        }
    }

    // MARK: - Blocking offload

    @Test
    func blockingOperationReturnsTheOperationResult() async throws {
        #expect(try await FeatureBlockingOperation.run { 42 } == 42)
        await #expect(throws: FeatureHostResolutionError.unresolvedHost("")) {
            try await FeatureBlockingOperation.run { try FeatureSystemHostResolver().resolve(host: "") }
        }
    }

    @Test
    func cancellationAbandonsABlockedOperationPromptly() async throws {
        let started = FeatureSingleResumeBox<Void>()
        let release = DispatchSemaphore(value: 0)
        let finished = FeatureSingleResumeBox<Int>()

        let task = Task {
            try await FeatureBlockingOperation.run(qos: .utility) {
                started.resume(returning: ())
                release.wait()
                finished.resume(returning: 7)
                return 7
            }
        }
        try await withCheckedThrowingContinuation { started.attach($0) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // The abandoned operation still completes on its dispatch thread; its
        // late result is discarded without a second resume.
        release.signal()
        let late: Int = try await withCheckedThrowingContinuation { finished.attach($0) }
        #expect(late == 7)
    }

    @Test
    func alreadyCancelledCallerGetsCancellationError() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FeatureBlockingOperation.run { 1 }
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
