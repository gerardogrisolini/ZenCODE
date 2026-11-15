//
//  DirectToolExecutorFeatureExposureTests.swift
//  ZenCODE
//
//  The session exposure of the Swift features a Builder sub-agent built, at
//  the level of `DirectToolExecutor` and the sub-agent runtime: descriptors
//  and execution for the delegating session only, no exposure under an empty
//  allowlist, the destructive gate on a tool reached only through the
//  exposure, the identity gate of the registration, the inheritance by
//  feature ID of a child created with the coordinator's own profile (and
//  of no other child), the revocation that reaches a live child, the
//  one-time announcement on `agent.*` output, and the propagation of the
//  delegation identity to the child executor of a remote backend.
//

import FeatureMCPBridgeKit
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectToolExecutorFeatureExposureTests {
    private static let announcementPrefix = "Feature tools now available in this session, built by your Builder sub-agent:"
    private static let coordinatorSessionID = "coordinator-session"

    // MARK: - Descriptors and execution

    @Test
    func anExposedFeatureIsListedAndExecutableOnlyForTheDelegatingSession() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: fixture.runtime,
            subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
        )
        let allowlist: Set<String> = ["local.readFile"]

        #expect(!(await Self.toolNames(executor, allowlist, sessionID: Self.coordinatorSessionID))
            .contains("built.run"))
        #expect(await executor.execute(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("built.run"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).status != .completed)

        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        for discovers in [true, false] {
            #expect(await Self.toolNames(
                executor,
                allowlist,
                sessionID: Self.coordinatorSessionID,
                discovers: discovers
            ).contains("built.run"))
        }
        let result = await executor.execute(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("built.run"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        )
        #expect(result.status == .completed)
        #expect(result.output == "built-output")

        // Another session, or no session, sees nothing.
        #expect(!(await Self.toolNames(executor, allowlist, sessionID: "other-session"))
            .contains("built.run"))
        #expect(!(await Self.toolNames(executor, allowlist, sessionID: nil)).contains("built.run"))
        #expect(await executor.execute(
            sessionID: "other-session",
            toolCall: Self.toolCall("built.run"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: allowlist
        ).status != .completed)
        await executor.shutdown()
    }

    @Test
    func descriptorsWithANilAllowlistOrWithoutASessionAreUnchanged() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: fixture.runtime,
            subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
        )
        let unrestricted = await Self.toolNames(executor, nil, sessionID: Self.coordinatorSessionID)
        let restrictedWithoutSession = await Self.toolNames(executor, ["local.readFile"], sessionID: nil)

        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        #expect(await Self.toolNames(executor, nil, sessionID: Self.coordinatorSessionID) == unrestricted)
        #expect(await Self.toolNames(executor, ["local.readFile"], sessionID: nil) == restrictedWithoutSession)
        await executor.shutdown()
    }

    /// An empty allowlist lists no tool and runs none, the exposed ones
    /// included.
    @Test
    func anEmptyAllowlistReachesNoExposedTool() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: fixture.runtime,
            subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
        )
        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        #expect(await Self.toolNames(executor, [], sessionID: Self.coordinatorSessionID).isEmpty)
        let result = await executor.execute(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("built.run"),
            workingDirectory: fixture.rootURL,
            allowedToolNames: []
        )
        #expect(result.status != .completed)
        #expect(result.output != "built-output")
        await executor.shutdown()
    }

    /// `git.push` is not a core name, so an exposure may grant it; the
    /// destructive gate still asks the operator before the feature runs.
    @Test
    func aDestructiveNameReachedOnlyThroughTheExposureStillAsksTheOperator() async throws {
        let rootURL = try SwiftFeatureSessionExposureTests.temporaryDirectory("exposure-destructive")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appendingPathComponent("ran")
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        touch '\(markerURL.path)'
        printf '{"ok":true,"output":"pushed"}\\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let runtime = SwiftFeatureRuntime(features: [
            SwiftFeatureBundle(
                id: "pusher-fixture",
                executableURL: executableURL,
                tools: [
                    ToolDescriptor(
                        name: "git.push",
                        description: "Pushes",
                        inputSchema: #"{"type":"object","properties":{}}"#
                    ),
                ]
            ),
        ])
        await runtime.exposeForTesting("pusher-fixture", sessionID: Self.coordinatorSessionID)
        let requests = Mutex<[String]>([])
        let approves = Mutex(false)
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                requests.withLock { $0.append(request.toolName) }
                return approves.withLock { $0 }
            },
            swiftFeatureRuntime: runtime,
            subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
        )
        let allowlist: Set<String> = ["local.readFile"]
        #expect(!DirectToolExecutor.isAllowed("git.push", allowedToolNames: allowlist))

        let denied = await executor.execute(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("git.push"),
            workingDirectory: rootURL,
            allowedToolNames: allowlist
        )
        #expect(denied.status == .permissionDenied)
        #expect(requests.withLock { $0 } == ["git.push"])
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        approves.withLock { $0 = true }
        let approved = await executor.execute(
            sessionID: Self.coordinatorSessionID,
            toolCall: Self.toolCall("git.push"),
            workingDirectory: rootURL,
            allowedToolNames: allowlist
        )
        #expect(approved.status == .completed)
        #expect(approved.output == "pushed")
        #expect(requests.withLock { $0 } == ["git.push", "git.push"])
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        await executor.shutdown()
    }

    // MARK: - Registration gate

    @Test
    func onlyABuilderSubAgentWithADelegatingSessionRegisters() async {
        let cases: [(ToolExecutionContext, String?)] = [
            (ToolExecutionContext(profileRole: .builder, isSubAgent: true, delegatingSessionID: "session-a"), "session-a"),
            (ToolExecutionContext(profileRole: .builder, isSubAgent: false, delegatingSessionID: "session-a"), nil),
            (ToolExecutionContext(profileRole: .developer, isSubAgent: true, delegatingSessionID: "session-a"), nil),
            (ToolExecutionContext(profileRole: nil, isSubAgent: true, delegatingSessionID: "session-a"), nil),
            (ToolExecutionContext(profileRole: .builder, isSubAgent: true, delegatingSessionID: nil), nil),
            (ToolExecutionContext(profileRole: .builder, isSubAgent: true, delegatingSessionID: "  "), nil),
        ]
        for (context, expected) in cases {
            let executor = DirectToolExecutor(
                toolExecutionContext: context,
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )
            #expect(await executor.featureExposureDelegatingSessionID == expected)
        }
    }

    @Test
    func onlyAnInheritingSubAgentReadsTheDelegatingSessionsExposures() async {
        let cases: [(ToolExecutionContext, String?)] = [
            (ToolExecutionContext(isSubAgent: true, delegatingSessionID: "session-a", inheritsFeatureExposures: true), "session-a"),
            (ToolExecutionContext(isSubAgent: true, delegatingSessionID: "session-a"), "own-session"),
            (ToolExecutionContext(isSubAgent: false, delegatingSessionID: "session-a", inheritsFeatureExposures: true), "own-session"),
            (ToolExecutionContext(isSubAgent: true, delegatingSessionID: nil, inheritsFeatureExposures: true), "own-session"),
        ]
        for (context, expected) in cases {
            let executor = DirectToolExecutor(
                toolExecutionContext: context,
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )
            #expect(await executor.featureExposureSessionID(for: "own-session") == expected)
        }
    }

    @Test
    func featureDeleteThroughABuilderExecutorRemovesTheExposureEverywhere() async throws {
        let rootURL = try SwiftFeatureSessionExposureTests.temporaryDirectory("executor-exposure-delete")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            _ = try await runtime.executeManagementTool(
                toolCall: SwiftFeatureSessionExposureTests.managementCall(
                    "feature.scaffold",
                    ["id": "builder-fixture", "toolName": "builder.echo"]
                )
            )
            await runtime.exposeForTesting("builder-fixture", sessionID: "session-a")
            await runtime.exposeForTesting("builder-fixture", sessionID: "session-b")
            let builder = DirectToolExecutor(
                swiftFeatureRuntime: runtime,
                sharedChatSenderID: "builder-agent",
                sharedChatRootSessionID: "session-a",
                toolExecutionContext: ToolExecutionContext(
                    profileRole: .builder,
                    isSubAgent: true,
                    delegatingSessionID: "session-a"
                ),
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )

            let output = try await builder.executeThrowingResult(
                sessionID: "builder-agent_session",
                toolCall: SwiftFeatureSessionExposureTests.managementCall(
                    "feature.delete",
                    ["id": "builder-fixture"]
                ),
                workingDirectory: featuresURL,
                allowedToolNames: ["feature.delete"]
            ).output

            // The JSON report of a `feature.*` tool is never annotated.
            let report = try JSONDecoder().decode(SwiftFeatureDeleteReport.self, from: Data(output.utf8))
            #expect(report.removed)
            #expect(!output.contains(Self.announcementPrefix))
            #expect(await runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            await builder.shutdown()
        }
    }

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
                requestedRole: "builder",
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

    // MARK: - Fixtures

    private struct FeatureFixture {
        static let featureID = "built-fixture"
        let rootURL: URL
        let runtime: SwiftFeatureRuntime

        /// `rivalFirst` loads, before the exposed feature, another feature
        /// with a tool in the same `built.` namespace.
        init(rivalFirst: Bool = false) throws {
            rootURL = try SwiftFeatureSessionExposureTests.temporaryDirectory("executor-exposure")
            let executableURL = rootURL.appendingPathComponent("feature")
            try Self.writeExecutable(at: executableURL, output: "built-output")
            let rivalExecutableURL = rootURL.appendingPathComponent("rival")
            try Self.writeExecutable(at: rivalExecutableURL, output: "rival-output")
            let rival = SwiftFeatureBundle(
                id: "rival-fixture",
                executableURL: rivalExecutableURL,
                tools: [
                    ToolDescriptor(
                        name: "built.rival",
                        description: "Another feature's tool in the same namespace",
                        inputSchema: #"{"type":"object","properties":{}}"#
                    )
                ]
            )
            let built = SwiftFeatureBundle(
                id: Self.featureID,
                executableURL: executableURL,
                tools: [
                    ToolDescriptor(
                        name: "built.run",
                        description: "Runs the built fixture",
                        inputSchema: #"{"type":"object","properties":{}}"#
                    )
                ],
                toolNamePrefixes: ["built."]
            )
            runtime = SwiftFeatureRuntime(features: rivalFirst ? [rival, built] : [built])
        }

        private static func writeExecutable(at url: URL, output: String) throws {
            try """
            #!/bin/sh
            cat >/dev/null
            printf '{"ok":true,"output":"\(output)"}\\n'
            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
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

    private static func toolNames(
        _ executor: DirectToolExecutor,
        _ allowedToolNames: Set<String>?,
        sessionID: String?,
        discovers: Bool = true
    ) async -> [String] {
        await executor.descriptors(
            allowedToolNames: allowedToolNames,
            sessionID: sessionID,
            discoversFeatureTools: discovers
        ).map(\.name).sorted()
    }

    private static func toolCall(_ name: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: "\(name)-\(UUID().uuidString)", name: name, argumentsObject: [:], argumentsJSON: "{}")
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
