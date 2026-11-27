//
//  AgentCoreSessionRunnerFeatureRuntimeTests.swift
//  ZenCODE
//
//  The runner owns the session's `SwiftFeatureRuntime`, whose persistent
//  feature processes hold connections such as the authorized Xcode bridge of
//  `xcode-tools`. A backend rebuilt for a model change must receive that same
//  runtime from the backend factory, otherwise the old runtime is released,
//  its processes are closed, and Xcode asks for consent again.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

/// Records what each backend construction receives from the runner.
private final class FeatureRuntimeConstructionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [AgentRuntimeConfiguration] = []

    func record(_ configuration: AgentRuntimeConfiguration) {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
    }

    var recordedConfigurations: [AgentRuntimeConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }
}

@Suite
struct AgentCoreSessionRunnerFeatureRuntimeTests {
    @Test
    func aBackendRebuiltForAnotherModelReceivesTheRunnerFeatureRuntime() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCoreSessionRunnerFeatureRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workingDirectory = support.resolvingSymlinksInPath()

        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let sessionRuntime = SwiftFeatureRuntime()
            let recorder = FeatureRuntimeConstructionRecorder()
            let runner = AgentCoreSessionRunner(
                swiftFeatureRuntime: sessionRuntime,
                backendFactory: { configuration, _ in
                    recorder.record(configuration)
                    return CapturingAgentRuntimeBackend()
                },
                taskGraphStore: nil,
                sessionTurnLease: AgentSessionTurnLease(),
                memoryGraphStoreRegistry: MemoryGraphStoreRegistry()
            )
            let sessionID = "session-\(UUID().uuidString)"

            for modelID in ["model-a", "model-b"] {
                let configuration = AgentCoreSessionConfiguration(
                    sessionID: sessionID,
                    modelID: modelID,
                    workingDirectory: workingDirectory,
                    systemPrompt: nil,
                    cacheKey: nil,
                    history: [],
                    allowedToolNames: []
                )
                _ = try await runner.sendPrompt(
                    configuration: configuration,
                    prompt: "hello \(modelID)",
                    attachments: [],
                    onEvent: { _ in }
                )
            }

            let constructions = recorder.recordedConfigurations
            try #require(constructions.count == 2)
            #expect(constructions.map(\.modelID) == ["model-a", "model-b"])
            for construction in constructions {
                #expect(construction.swiftFeatureRuntime === sessionRuntime)
            }
            await runner.shutdown()
        }
    }
}
