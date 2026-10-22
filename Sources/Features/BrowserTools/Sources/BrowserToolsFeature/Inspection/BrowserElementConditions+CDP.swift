//
//  BrowserElementConditions+CDP.swift
//  BrowserToolsFeature
//
//  Snapshot-bound CDP helpers for element conditions.
//

import FeatureKit
import ToolCore
import Dispatch

// MARK: - Snapshot-bound CDP helpers

extension CDPSession {
    /// Validates the snapshot/ref before resolving the current accessibility
    /// target. A deleted target is normal state for absent/hidden, but a stale
    /// snapshot is an authorization failure and always escapes to the caller.
    func resolveElementConditionTarget(authorization: BrowserSnapshotAuthorization) async throws -> BrowserAccessibilityTarget? {
        guard let ref = authorization.ref else { throw BrowserInteractionError.staleSnapshot }
        try await validateSnapshotState(authorization)
        _ = try await send(method: "DOM.enable")
        do {
            let target = try await accessibilityTarget(for: ref)
            try await validateSnapshotState(authorization)
            return target
        } catch let error as BrowserInteractionError {
            guard case .targetNoLongerAvailable = error else {
                // Prefer a fail-closed stale-snapshot error if the resolution
                // raced navigation; otherwise preserve the original failure.
                try await validateSnapshotState(authorization)
                throw error
            }
            try await validateSnapshotState(authorization)
            return nil
        } catch {
            try await validateSnapshotState(authorization)
            throw error
        }
    }

    /// Surrounding the fixed probe with snapshot checks prevents a navigation
    /// race from being interpreted as a successful absent/hidden condition.
    func evaluateElementCondition(
        authorization: BrowserSnapshotAuthorization,
        target: BrowserAccessibilityTarget?,
        condition: BrowserElementCondition,
        literal: BrowserElementConditionLiteral?
    ) async throws -> BrowserElementConditionEvaluation {
        try await validateSnapshotState(authorization)
        let probe = try await elementConditionProbe(target: target, authorization: authorization)
        try await validateSnapshotState(authorization)
        return condition.evaluate(probe: probe, literal: literal)
    }

    /// A mismatch is data. Snapshot authorization errors remain fail-closed;
    /// transient CDP errors are retried only until the fixed deadline.
    func waitForElementCondition(
        authorization: BrowserSnapshotAuthorization,
        condition: BrowserElementCondition,
        literal: BrowserElementConditionLiteral?,
        timeoutSeconds: Int
    ) async throws -> BrowserElementWaitResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        let (deadline, didOverflowDeadline) = start.addingReportingOverflow(timeoutNanoseconds)
        let boundedDeadline = didOverflowDeadline ? UInt64.max : deadline
        var latestEvaluation: BrowserElementConditionEvaluation?
        var target: BrowserAccessibilityTarget?
        var didResolveTarget = false

        func timedOutResult() -> BrowserElementWaitResult {
            BrowserElementWaitResult(
                evaluation: latestEvaluation,
                timedOut: true,
                elapsedMilliseconds: elementConditionElapsedMilliseconds(since: start)
            )
        }

        /// Sleeps one poll interval, or returns false once the deadline passed.
        func sleepUntilNextPoll() async throws -> Bool {
            guard let remaining = BrowserElementConditionProbeRace.remaining(until: boundedDeadline) else { return false }
            try await Task.sleep(
                nanoseconds: min(UInt64(BrowserElementConditionLimits.pollIntervalMilliseconds) * 1_000_000, remaining)
            )
            return true
        }

        while true {
            try Task.checkCancellation()
            guard BrowserElementConditionProbeRace.remaining(until: boundedDeadline) != nil else { return timedOutResult() }

            if !didResolveTarget {
                do {
                    guard let resolution = try await BrowserElementConditionProbeRace.race(
                        until: boundedDeadline,
                        operation: {
                            BrowserElementConditionTargetResolution(
                                target: try await self.resolveElementConditionTarget(authorization: authorization)
                            )
                        }
                    ) else {
                        return timedOutResult()
                    }
                    target = resolution.target
                    didResolveTarget = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch where isTerminated {
                    throw error
                } catch let error as BrowserInteractionError {
                    if case .staleSnapshot = error {
                        throw error
                    }
                    // A target-resolution race is not an absent observation.
                    // Retry it under the same deadline before probing.
                } catch {
                    // CDP lifecycle/context errors during initial resolution
                    // are retried under the same absolute deadline.
                }

                if !didResolveTarget {
                    guard try await sleepUntilNextPoll() else { return timedOutResult() }
                    continue
                }
            }

            let probeTarget = target
            do {
                guard let evaluation = try await BrowserElementConditionProbeRace.race(
                    until: boundedDeadline,
                    operation: {
                        try await self.evaluateElementCondition(
                            authorization: authorization,
                            target: probeTarget,
                            condition: condition,
                            literal: literal
                        )
                    }
                ) else {
                    return timedOutResult()
                }
                latestEvaluation = evaluation
                if evaluation.satisfied {
                    return BrowserElementWaitResult(
                        evaluation: evaluation,
                        timedOut: false,
                        elapsedMilliseconds: elementConditionElapsedMilliseconds(since: start)
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch where isTerminated {
                // A closed session cannot recover within the deadline.
                throw error
            } catch let error as BrowserInteractionError {
                if case .staleSnapshot = error {
                    throw error
                }
                // Other target/probe races are retried until the deadline.
            } catch {
                // A lifecycle transition can briefly invalidate the fixed DOM
                // probe. It is not an absent observation and cannot satisfy a
                // condition; a normal timeout remains structured data.
            }

            guard try await sleepUntilNextPoll() else { return timedOutResult() }
        }
    }

    private func elementConditionProbe(
        target: BrowserAccessibilityTarget?,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserElementConditionProbe {
        guard let target else { return .absent }

        do {
            let response = try await snapshotBoundRead(
                authorization,
                method: "DOM.resolveNode",
                params: ["backendNodeId": target.backendDOMNodeID]
            )
            guard let result = response["result"] as? [String: Any],
                  let object = result["object"] as? [String: Any],
                  let objectID = object["objectId"] as? String,
                  !objectID.isEmpty
            else {
                throw BrowserInteractionError.targetNoLongerAvailable(target.ref)
            }

            do {
                let json = try await callFixedElementConditionFunction(objectID: objectID, authorization: authorization)
                _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": objectID])
                return try BrowserElementConditionProbeCapture.decode(json)
            } catch {
                _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": objectID])
                throw error
            }
        } catch let error as BrowserInteractionError {
            guard case .targetNoLongerAvailable = error else { throw error }
            return .absent
        } catch {
            if BrowserElementConditionProbeCapture.isTargetNoLongerAvailable(error) {
                return .absent
            }
            throw error
        }
    }

    private func callFixedElementConditionFunction(
        objectID: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> String {
        let response = try await snapshotBoundRead(
            authorization,
            method: "Runtime.callFunctionOn",
            params: [
                "objectId": objectID,
                "functionDeclaration": BrowserElementConditionProbeCapture.functionDeclaration,
                "returnByValue": true,
                "awaitPromise": true,
            ]
        )
        let result = response["result"] as? [String: Any] ?? [:]
        if let exceptionDetails = result["exceptionDetails"] {
            let description = (exceptionDetails as? [String: Any])?["text"] as? String
                ?? String(describing: exceptionDetails)
            throw CDPError.javaScriptError(description)
        }
        guard let remoteObject = result["result"] as? [String: Any],
              let value = remoteObject["value"] as? String
        else {
            throw CDPError.invalidResponse("Browser element condition probe did not return a string")
        }
        return value
    }

    private func elementConditionElapsedMilliseconds(since start: UInt64) -> Int {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        return Int(min(elapsedNanoseconds / 1_000_000, UInt64(Int.max)))
    }
}
