//
//  AgentCoreSessionRunnerFeatureExposureTests.swift
//  ZenCODE
//
//  Lifecycle of the Swift features a Builder sub-agent exposed to a session:
//  no exposure survives the end of the conversation (reset, close, shutdown)
//  or a change of the session's agent profile, while compaction, a history
//  replacement, a model change, an option update, and a `/tools` rebuild keep
//  it. A full reset and a shutdown end only the conversations of the runner
//  that performs them. The Chat controller reaches the runner only through
//  these entry points: `/agents` and a model change both shut the backend
//  down and create the session again, `/sessions new` and a saved-session
//  load reset (or close, in a host slot) the previous session first.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct AgentCoreSessionRunnerFeatureExposureTests {
    private static let featureID = "lifecycle-fixture"

    @Test
    func compactionHistoryReplacementAndOptionUpdatesKeepTheExposure() async throws {
        let fixture = Fixture()
        try await fixture.runner.createSession(configuration: fixture.configuration())
        await fixture.expose()

        _ = try await fixture.runner.compactSession(id: fixture.sessionID, force: true)
        #expect(await fixture.isExposed())

        let generation = try #require(await fixture.runner.currentSessionGeneration(for: fixture.sessionID))
        _ = await fixture.runner.replaceSessionHistory(
            id: fixture.sessionID,
            history: [AgentRuntimeMessage(role: .user, content: "compacted")],
            expectedSessionGeneration: generation
        )
        #expect(await fixture.isExposed())

        try await fixture.runner.updateSessionOptions(
            configuration: fixture.configuration(systemPrompt: "updated", allowedToolNames: ["local.read"])
        )
        #expect(await fixture.isExposed())

        // `/tools`: the session is rebuilt and created again, same profile.
        await fixture.runner.rebuildSession(id: fixture.sessionID)
        try await fixture.runner.createSession(
            configuration: fixture.configuration(allowedToolNames: ["local.write"])
        )
        #expect(await fixture.isExposed())
        await fixture.runner.shutdown()
    }

    @Test
    func aModelChangeKeepsTheExposureAndAnAgentChangeRevokesIt() async throws {
        let fixture = Fixture()
        try await fixture.runner.createSession(configuration: fixture.configuration())
        await fixture.expose()

        // Model change: backend reset, session created again, same profile.
        await fixture.runner.shutdownBackendKeepingExternalTools()
        try await fixture.runner.createSession(configuration: fixture.configuration(modelID: "other-model"))
        #expect(await fixture.isExposed())

        // Agent change: backend reset, session created again, new profile.
        await fixture.runner.shutdownBackendKeepingExternalTools()
        try await fixture.runner.createSession(
            configuration: fixture.configuration(
                modelID: "other-model",
                agentID: AgentProfileRole.reviewer.rawValue,
                agentName: "Reviewer",
                agentRole: .reviewer
            )
        )
        #expect(!(await fixture.isExposed()))
        await fixture.runner.shutdown()
    }

    @Test
    func anOptionUpdateWithAnotherProfileRevokesTheExposure() async throws {
        let fixture = Fixture()
        try await fixture.runner.createSession(configuration: fixture.configuration())
        await fixture.expose()

        try await fixture.runner.updateSessionOptions(
            configuration: fixture.configuration(
                agentID: AgentProfileRole.reviewer.rawValue,
                agentName: "Reviewer",
                agentRole: .reviewer
            )
        )
        #expect(!(await fixture.isExposed()))
        await fixture.runner.shutdown()
    }

    @Test
    func resetAndCloseEndTheConversationAndRevokeOnlyThatSession() async throws {
        let fixture = Fixture()
        let otherSessionID = "other-\(UUID().uuidString)"
        try await fixture.runner.createSession(configuration: fixture.configuration())
        try await fixture.runner.createSession(configuration: fixture.configuration(sessionID: otherSessionID))
        await fixture.expose()
        await fixture.expose(sessionID: otherSessionID)

        // `/sessions new` and a saved-session load reset the previous session.
        await fixture.runner.resetSession(id: fixture.sessionID)
        #expect(!(await fixture.isExposed()))
        #expect(await fixture.isExposed(sessionID: otherSessionID))

        // A closed host slot closes its session.
        await fixture.runner.closeSession(id: otherSessionID)
        #expect(!(await fixture.isExposed(sessionID: otherSessionID)))

        // Created again with the same id: a fresh conversation, no exposure.
        await fixture.expose()
        await fixture.runner.closeSession(id: fixture.sessionID)
        try await fixture.runner.createSession(configuration: fixture.configuration())
        #expect(!(await fixture.isExposed()))
        await fixture.runner.shutdown()
    }

    @Test
    func aFullResetAndShutdownRevokeOnlyTheSessionsOfThatRunner() async throws {
        let fixture = Fixture()
        // Another runner (another host slot) that shares the feature runtime.
        let otherRunner = fixture.makeRunner()
        let otherSessionID = "other-runner-\(UUID().uuidString)"
        try await fixture.runner.createSession(configuration: fixture.configuration())
        try await otherRunner.createSession(configuration: fixture.configuration(sessionID: otherSessionID))
        await fixture.expose()
        await fixture.expose(sessionID: otherSessionID)

        await fixture.runner.resetSession()
        #expect(!(await fixture.isExposed()))
        #expect(await fixture.isExposed(sessionID: otherSessionID))

        try await fixture.runner.createSession(configuration: fixture.configuration())
        await fixture.expose()
        await fixture.runner.shutdown()
        #expect(!(await fixture.isExposed()))
        #expect(await fixture.isExposed(sessionID: otherSessionID))

        await otherRunner.shutdown()
        #expect(!(await fixture.isExposed(sessionID: otherSessionID)))
    }

    // MARK: - Fixture

    private struct Fixture {
        let sessionID = "exposure-session-\(UUID().uuidString)"
        let featureRuntime: SwiftFeatureRuntime
        let runner: AgentCoreSessionRunner

        init() {
            featureRuntime = SwiftFeatureRuntime(features: [
                SwiftFeatureSessionExposureTests.bundle(
                    id: AgentCoreSessionRunnerFeatureExposureTests.featureID,
                    tools: ["lifecycle.run"]
                )
            ])
            runner = Self.makeRunner(featureRuntime: featureRuntime)
        }

        /// A runner over the same feature runtime.
        func makeRunner() -> AgentCoreSessionRunner {
            Self.makeRunner(featureRuntime: featureRuntime)
        }

        private static func makeRunner(featureRuntime: SwiftFeatureRuntime) -> AgentCoreSessionRunner {
            let backend = CapturingSubAgentRuntimeBackend()
            return AgentCoreSessionRunner(
                swiftFeatureRuntime: featureRuntime,
                backendFactory: { _, _ in backend },
                taskGraphStore: nil
            )
        }

        func configuration(
            sessionID: String? = nil,
            modelID: String = "test-model",
            agentID: String = AgentProfileRole.developer.rawValue,
            agentName: String = "Developer",
            agentRole: AgentProfileRole = .developer,
            systemPrompt: String = "prompt",
            allowedToolNames: Set<String> = ["agent.create"]
        ) -> AgentCoreSessionConfiguration {
            AgentCoreSessionConfiguration(
                sessionID: sessionID ?? self.sessionID,
                modelID: modelID,
                agentID: agentID,
                agentName: agentName,
                agentRole: agentRole,
                workingDirectory: FileManager.default.temporaryDirectory,
                systemPrompt: systemPrompt,
                cacheKey: nil,
                history: [
                    AgentRuntimeMessage(role: .user, content: "build a feature"),
                    AgentRuntimeMessage(role: .assistant, content: "delegated to a Builder"),
                ],
                allowedToolNames: allowedToolNames
            )
        }

        func expose(sessionID: String? = nil) async {
            await featureRuntime.exposeForTesting(
                AgentCoreSessionRunnerFeatureExposureTests.featureID,
                sessionID: sessionID ?? self.sessionID
            )
        }

        func isExposed(sessionID: String? = nil) async -> Bool {
            await featureRuntime.exposedFeatureIDs(sessionID: sessionID ?? self.sessionID)
                .contains(AgentCoreSessionRunnerFeatureExposureTests.featureID)
        }
    }
}
