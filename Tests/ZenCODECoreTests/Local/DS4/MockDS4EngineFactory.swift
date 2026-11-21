//
//  MockDS4EngineFactory.swift
//  ZenCODE
//
//  Registry factory for DS4 tests: counts opens, keeps the opened mock
//  engines and fails the next opens with scripted errors.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

// MARK: - Factory

/// Registry factory for tests: counts opens, keeps the opened mocks in
/// order, can delay opens and fail the next ones with scripted errors.
final class MockDS4EngineFactory: Sendable {
    private struct State {
        var engines: [MockDS4Engine] = []
        var openCount = 0
        var failures: [DS4EngineError] = []
        var statusMessages: [String] = []
    }

    let openDelay: Duration
    private let makeEngine: @Sendable (DS4EngineConfiguration) -> MockDS4Engine
    private let state = Mutex(State())

    init(
        openDelay: Duration = .zero,
        makeEngine: @escaping @Sendable (DS4EngineConfiguration) -> MockDS4Engine = { MockDS4Engine(configuration: $0) }
    ) {
        self.openDelay = openDelay
        self.makeEngine = makeEngine
    }

    var engines: [MockDS4Engine] {
        state.withLock { $0.engines }
    }

    var openCount: Int {
        state.withLock { $0.openCount }
    }

    var statusMessages: [String] {
        state.withLock { $0.statusMessages }
    }

    /// The next open throws `error` (after `openDelay`).
    func failNextOpen(with error: DS4EngineError) {
        state.withLock { $0.failures.append(error) }
    }

    var factory: DS4EngineRegistry.Factory {
        { [self] configuration, onStatus in
            try await open(configuration, onStatus: onStatus)
        }
    }

    func open(
        _ configuration: DS4EngineConfiguration,
        onStatus: @escaping DS4EngineRegistry.StatusHandler
    ) async throws -> any DS4Engine {
        state.withLock { $0.openCount += 1 }
        if openDelay > .zero {
            try? await Task.sleep(for: openDelay)
        }
        if let failure = state.withLock({ $0.failures.isEmpty ? nil : $0.failures.removeFirst() }) {
            throw failure
        }
        let engine = makeEngine(configuration)
        state.withLock { $0.engines.append(engine) }
        let message = "opened \(configuration.modelPath ?? "mock")"
        state.withLock { $0.statusMessages.append(message) }
        await onStatus(message)
        return engine
    }
}
