//
//  JiraBrowserSetupState.swift
//  ZenCODE
//
//  Thread-safe continuation storage of the Jira browser setup server, shared
//  between the listener queue and the awaiting task.
//

import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

#if os(macOS)
import Network

/// Thread-safe continuation storage for the setup server, shared across the
/// listener queue and the awaiting task.
final class JiraBrowserSetupState: Sendable {
    private struct State: Sendable {
        var readinessContinuation: CheckedContinuation<Void, Error>?
        var readinessTimeout: Task<Void, Never>?
        var resultContinuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>?
        var pendingResult: Result<JiraAuthenticatedConfiguration, Error>?
        var didResumeReadiness = false
        var didResumeResult = false
        var isStopped = false
        var isValidatingSubmission = false
        var submissionTask: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func setReadiness(_ continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>? = nil) {
        state.withLock { state in
            state.readinessContinuation = continuation
            state.readinessTimeout = timeout
            return
        }
    }

    func resumeReadiness(with result: Result<Void, Error>) {
        let resumption: (CheckedContinuation<Void, Error>, Task<Void, Never>?)? = state.withLock { state in
            guard !state.didResumeReadiness, let continuation = state.readinessContinuation else { return nil }
            state.didResumeReadiness = true
            state.readinessContinuation = nil
            let timeout = state.readinessTimeout
            state.readinessTimeout = nil
            return (continuation, timeout)
        }
        if let (continuation, timeout) = resumption {
            timeout?.cancel()
            continuation.resume(with: result)
        }
    }

    /// Registers the result continuation, or returns a buffered result if the
    /// server resolved before the waiter attached.
    func takeResult(
        orRegister continuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>
    ) -> Result<JiraAuthenticatedConfiguration, Error>? {
        state.withLock { state in
            if let pending = state.pendingResult {
                state.pendingResult = nil
                state.didResumeResult = true
                return pending
            }
            state.resultContinuation = continuation
            return nil
        }
    }

    func resumeResult(with result: Result<JiraAuthenticatedConfiguration, Error>) {
        let continuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>? = state.withLock { state in
            guard !state.didResumeResult else { return nil }
            guard let continuation = state.resultContinuation else {
                state.didResumeResult = true
                if state.pendingResult == nil {
                    state.pendingResult = result
                }
                return nil
            }
            state.didResumeResult = true
            state.resultContinuation = nil
            return continuation
        }
        if let continuation {
            continuation.resume(with: result)
        }
    }

    /// Starts at most one credential validation at a time. The listener queue
    /// may receive simultaneous browser POSTs, while the actual validation runs
    /// asynchronously, so this state must be protected independently of that
    /// queue.
    func beginSubmission() -> Bool {
        state.withLock { state in
            guard !state.isStopped, !state.didResumeResult, !state.isValidatingSubmission else { return false }
            state.isValidatingSubmission = true
            return true
        }
    }

    /// Keeps the asynchronous validator owned by the server. If teardown won
    /// the small race between `beginSubmission` and task creation, cancellation
    /// is requested immediately rather than letting a detached validation outlive
    /// the loopback setup flow.
    func setSubmissionTask(_ task: Task<Void, Never>) {
        let cancelTask = state.withLock { state -> Bool in
            guard !state.isStopped, state.isValidatingSubmission else { return true }
            state.submissionTask = task
            return false
        }
        if cancelTask {
            task.cancel()
        }
    }

    /// Finishes the active submission. Only a successful result can resolve the
    /// setup continuation; failed validation simply permits a new POST. Results
    /// after timeout/stop are ignored, preventing late persistence by callers.
    func finishSubmission(with result: Result<JiraAuthenticatedConfiguration, JiraSetupValidationError>) -> Bool {
        let completion = state.withLock { state -> (CheckedContinuation<JiraAuthenticatedConfiguration, Error>?, Bool) in
            state.isValidatingSubmission = false
            state.submissionTask = nil
            guard !state.isStopped, !state.didResumeResult else { return (nil, false) }
            switch result {
            case let .success(configuration):
                let accepted: Result<JiraAuthenticatedConfiguration, Error> = .success(configuration)
                state.didResumeResult = true
                if let continuation = state.resultContinuation {
                    state.resultContinuation = nil
                    return (continuation, true)
                }
                state.pendingResult = accepted
                return (nil, true)
            case .failure:
                return (nil, true)
            }
        }

        if case let .success(configuration) = result {
            completion.0?.resume(returning: configuration)
        }
        return completion.1
    }

    func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isStopped = true
            state.isValidatingSubmission = false
            let task = state.submissionTask
            state.submissionTask = nil
            return task
        }
        task?.cancel()
        resumeResult(with: .failure(CancellationError()))
    }
}
#endif
