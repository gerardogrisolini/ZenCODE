//
//  ds4Eventually.swift
//  ZenCODE
//
//  Polling helper that waits for a condition in DS4 tests.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Polls `condition` every few milliseconds; records an issue after `timeout`.
func ds4Eventually(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
}
