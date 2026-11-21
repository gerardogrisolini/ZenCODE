//
//  DirectToolExecutorFeatureExposureTests+Inheritance.swift
//  ZenCODE
//
//  Inheritance, announcement and delegation identity tests of the feature
//  exposure, with the coordinator and child executor fixtures they use.
//

import FeatureMCPBridgeKit
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension DirectToolExecutorFeatureExposureTests {
    // MARK: - Inheritance and announcement

    @Test
    func aSameProfileChildInheritsByIDNotThroughItsAllowlistAndTheAnnouncementIsAppendedOnce() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let executor = Self.developerCoordinator(fixture: fixture, backend: backend, recorder: recorder)
        let allowlist: Set<String> = ["local.readFile", "agent.create", "agent.list"]
        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        let sameProfile = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.agentCreateCall(name: "same-profile-worker", profile: "Developer"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).output
        let otherProfile = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.agentCreateCall(name: "other-profile-worker", profile: "Reviewer"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).output
        let builderProfile = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.agentCreateCall(name: "builder-worker", profile: "Builder"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).output
        let list = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("agent.list"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).output

        #expect(sameProfile.components(separatedBy: Self.announcementPrefix).count == 2)
        #expect(sameProfile.hasSuffix(
            "\(Self.announcementPrefix) \(FeatureFixture.featureID) (built.run, tools with prefix `built.`). "
                + "Call them directly."
        ))
        for output in [otherProfile, builderProfile, list] {
            #expect(!output.contains(Self.announcementPrefix))
        }

        // No child allowlist names the feature: inheritance is by ID only.
        let sessions = await backend.createdSessions()
        #expect(sessions.count == 3)
        for session in sessions {
            let grant = try #require(session.allowedToolNames)
            #expect(!grant.contains("built.run"))
            #expect(!grant.contains("built."))
        }
        // Only the child with the coordinator's own profile inherits; a
        // Builder with another profile does not.
        #expect(recorder.contexts.map(\.inheritsFeatureExposures) == [true, false, false])
        #expect(recorder.contexts.map(\.delegatingSessionID)
            == Array(repeating: Self.coordinatorSessionID, count: 3))
        await executor.shutdown()
    }

    /// The child with the coordinator's own profile, through its real
    /// executor: it lists and runs the exposed feature by ID, but neither a
    /// tool of another feature nor one of an MCP server in the same
    /// namespace; a child with another profile sees none of it; revoking the
    /// coordinator's exposures reaches the live child.
    @Test
    func aSameProfileChildSeesTheExposedFeatureAndNothingElseInItsNamespace() async throws {
        let fixture = try FeatureFixture(rivalFirst: true)
        defer { fixture.remove() }
        let supportURL = fixture.rootURL.appendingPathComponent("support", isDirectory: true)
        try await AppStorageDirectory.withSupportDirectoryURL(supportURL) {
            let backend = CapturingSubAgentRuntimeBackend()
            let recorder = SubAgentFactoryRecorder()
            let executor = Self.developerCoordinator(fixture: fixture, backend: backend, recorder: recorder)
            let allowlist: Set<String> = ["local.readFile", "agent.create"]
            await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)
            for (name, profile) in [("same-profile-worker", "Developer"), ("other-profile-worker", "Reviewer")] {
                _ = try await executor.executeThrowingResult(
                    sessionID: Self.coordinatorSessionID,
                    toolCall: Self.agentCreateCall(name: name, profile: profile),
                    workingDirectory: fixture.rootURL,
                    allowedToolNames: allowlist
                )
            }
            let sessions = await backend.createdSessions()
            let contexts = recorder.contexts
            try #require(sessions.count == 2 && contexts.count == 2)

            let mcpRuntime = DirectMCPToolRuntime()
            _ = await mcpRuntime.installBorrowedExternalExecutor(
                name: "built",
                executor: RemoteMCPToolExecutor(
                    configuration: MCPServerConfiguration(
                        executablePath: "/usr/bin/false",
                        arguments: [],
                        environment: [:]
                    ),
                    toolNamePrefix: "built."
                ),
                tools: [
                    ToolDescriptor(
                        name: "mcpThing",
                        description: "An MCP tool in the feature's namespace",
                        inputSchema: #"{"type":"object"}"#
                    ),
                ]
            )
            let sameProfileChild = try await Self.childExecutor(
                for: contexts[0],
                featureRuntime: fixture.runtime,
                mcpRuntime: mcpRuntime
            )
            let otherProfileChild = try await Self.childExecutor(
                for: contexts[1],
                featureRuntime: fixture.runtime,
                mcpRuntime: mcpRuntime
            )
            let sameProfileGrant = sessions[0].allowedToolNames
            let otherProfileGrant = sessions[1].allowedToolNames
            // Present at the coordinator level, to make the absence meaningful.
            #expect(await mcpRuntime.knownDescriptors().map(\.name).contains("built.mcpThing"))

            let inherited = await Self.toolNames(sameProfileChild, sameProfileGrant, sessionID: sessions[0].id)
            #expect(inherited.contains("built.run"))
            #expect(!inherited.contains("built.rival"))
            #expect(!inherited.contains("built.mcpThing"))
            let run = await sameProfileChild.execute(
                sessionID: sessions[0].id,
                toolCall: Self.toolCall("built.run"),
                workingDirectory: fixture.rootURL,
                allowedToolNames: sameProfileGrant
            )
            #expect(run.status == .completed)
            #expect(run.output == "built-output")
            #expect(await sameProfileChild.execute(
                sessionID: sessions[0].id,
                toolCall: Self.toolCall("built.rival"),
                workingDirectory: fixture.rootURL,
                allowedToolNames: sameProfileGrant
            ).status != .completed)
            // The child's grant admits no MCP tool of that namespace: the MCP
            // dispatch step requires the raw name to be allowed (a call to
            // such a name is routed to the exposed feature, which owns the
            // `built.` prefix, never to the server).
            #expect(!DirectToolExecutor.isAllowed("built.mcpThing", allowedToolNames: sameProfileGrant))
            #expect(!(await mcpRuntime.knownDescriptors(
                allowedToolNames: sameProfileGrant,
                sessionID: Self.coordinatorSessionID
            ).map(\.name).contains("built.mcpThing")))

            #expect(!(await Self.toolNames(otherProfileChild, otherProfileGrant, sessionID: sessions[1].id))
                .contains("built.run"))
            #expect(await otherProfileChild.execute(
                sessionID: sessions[1].id,
                toolCall: Self.toolCall("built.run"),
                workingDirectory: fixture.rootURL,
                allowedToolNames: otherProfileGrant
            ).status != .completed)

            // The coordinator's conversation ends: the live child loses it too.
            await fixture.runtime.revokeExposures(sessionID: Self.coordinatorSessionID)
            #expect(!(await Self.toolNames(sameProfileChild, sameProfileGrant, sessionID: sessions[0].id))
                .contains("built.run"))
            #expect(await sameProfileChild.execute(
                sessionID: sessions[0].id,
                toolCall: Self.toolCall("built.run"),
                workingDirectory: fixture.rootURL,
                allowedToolNames: sameProfileGrant
            ).status != .completed)

            await sameProfileChild.shutdown()
            await otherProfileChild.shutdown()
            await mcpRuntime.shutdown()
            await executor.shutdown()
        }
    }

    /// An unrestricted coordinator gives every child an unrestricted grant,
    /// which already lists every feature: nothing to inherit.
    @Test
    func aNilAllowlistIsPassedToChildrenUnchangedAndNothingIsInherited() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let executor = Self.developerCoordinator(fixture: fixture, backend: backend, recorder: recorder)
        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        _ = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.agentCreateCall(name: "same-profile-worker", profile: "Developer"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: nil
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == nil)
        #expect(recorder.contexts.map(\.inheritsFeatureExposures) == [false])
        await executor.shutdown()
    }

    // MARK: - Delegation identity

    @Test
    func theDelegatingSessionIsTheSessionThatExecutesAgentCreate() async throws {
        let workingDirectory = try SwiftFeatureSessionExposureTests.temporaryDirectory("exposure-delegating")
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let recorder = SubAgentFactoryRecorder()
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )

        _ = try await executor.executeThrowingResult(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.agentCreateCall(name: "builder", profile: "Builder"),
            workingDirectory: workingDirectory,
            allowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.delegatingSessionID == Self.coordinatorSessionID)
        #expect(context.sharedChatRoomID == Self.coordinatorSessionID)
        #expect(context.injecting(swiftFeatureRuntime: SwiftFeatureRuntime()).delegatingSessionID
            == Self.coordinatorSessionID)
        await executor.shutdown()
    }

    @Test
    func theDelegationIdentityReachesTheChildExecutorOfARemoteBackend() async throws {
        let builderProfile = try #require(
            AgentProfileStore.defaultProfiles().first { $0.role == .builder }
        )
        for inherits in [false, true] {
            let context = DirectSubAgentRuntime.BackendContext(
                requestedName: "Builder 1",
                profile: builderProfile,
                sharedChatSenderID: "builder-agent",
                sharedChatRoomID: Self.coordinatorSessionID,
                delegatingSessionID: Self.coordinatorSessionID,
                inheritsFeatureExposures: inherits
            )
            let configuration = AgentRuntimeConfiguration(
                modelID: "gpt-exposure-propagation",
                workingDirectory: URL(fileURLWithPath: "/tmp/exposure-propagation", isDirectory: true),
                maxToolRounds: 1,
                toolAuthorizationHandler: nil
            ).applyingSubAgentBackendContext(context)
            #expect(configuration.delegatingSessionID == Self.coordinatorSessionID)
            #expect(configuration.inheritsFeatureExposures == inherits)
            #expect(configuration.withModelID("other-model").delegatingSessionID == Self.coordinatorSessionID)
            #expect(configuration.withModelID("other-model").inheritsFeatureExposures == inherits)

            let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
                configuration: configuration,
                mcpRuntime: DirectMCPToolRuntime(),
                resolvedModelSelection: Self.remoteSelection(modelID: "gpt-exposure-propagation"),
                sharedChatSenderID: context.sharedChatSenderID,
                sharedChatRootSessionID: context.sharedChatRoomID
            )
            let client = try #require(backend as? RemoteGenerationClient)
            let toolExecutor = await client.toolExecutor
            let executionContext = await toolExecutor.toolExecutionContext
            #expect(executionContext.isSubAgent)
            #expect(executionContext.profileRole == .builder)
            #expect(executionContext.delegatingSessionID == Self.coordinatorSessionID)
            #expect(executionContext.inheritsFeatureExposures == inherits)
            #expect(await toolExecutor.featureExposureDelegatingSessionID == Self.coordinatorSessionID)
            #expect(await toolExecutor.featureExposureSessionID(for: "builder-agent_session")
                == (inherits ? Self.coordinatorSessionID : "builder-agent_session"))
            await client.shutdown()
        }
    }

    /// A coordinator with the Developer profile whose children are created
    /// through `backend` and recorded by `recorder`.
    private static func developerCoordinator(
        fixture: FeatureFixture,
        backend: CapturingSubAgentRuntimeBackend,
        recorder: SubAgentFactoryRecorder
    ) -> DirectToolExecutor {
        DirectToolExecutor(
            swiftFeatureRuntime: fixture.runtime,
            toolExecutionContext: ToolExecutionContext(
                profileID: AgentProfileRole.developer.rawValue,
                profileName: "Developer",
                profileRole: .developer
            ),
            subAgentContextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
    }

    /// The tool executor of the remote backend a child created with
    /// `context` gets, sharing `featureRuntime`.
    private static func childExecutor(
        for context: DirectSubAgentRuntime.BackendContext,
        featureRuntime: SwiftFeatureRuntime,
        mcpRuntime: DirectMCPToolRuntime
    ) async throws -> DirectToolExecutor {
        let configuration = AgentRuntimeConfiguration(
            modelID: "gpt-exposure-child",
            workingDirectory: FileManager.default.temporaryDirectory,
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        ).applyingSubAgentBackendContext(context)
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            resolvedModelSelection: remoteSelection(modelID: "gpt-exposure-child"),
            swiftFeatureRuntime: featureRuntime,
            sharedChatSenderID: context.sharedChatSenderID,
            sharedChatRootSessionID: context.sharedChatRoomID
        )
        let client = try #require(backend as? RemoteGenerationClient)
        return await client.toolExecutor
    }

    private static func agentCreateCall(name: String, profile: String) -> DirectAgentToolCall {
        let arguments: [String: Any] = ["name": name, "profile": profile, "prompt": "Work."]
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: "agent-create-\(UUID().uuidString)",
            name: "agent.create",
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }

    private static func remoteSelection(modelID: String) -> AgentModelSelection {
        AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: modelID,
            remoteProvider: AgentRemoteProvider(
                name: "OpenAI API",
                baseURL: "https://api.openai.com/v1",
                modelID: modelID,
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "unit-test-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
    }
}
