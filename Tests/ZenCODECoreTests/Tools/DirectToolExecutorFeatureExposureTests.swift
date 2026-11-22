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
@testable import ZenCODERuntime

@Suite
struct DirectToolExecutorFeatureExposureTests {
    static let announcementPrefix = "Feature tools now available in this session, built by your Builder sub-agent:"
    static let coordinatorSessionID = "coordinator-session"

    // MARK: - Descriptors and execution

    @Test
    func anExposedFeatureIsListedAndExecutableOnlyForTheDelegatingSession() async throws {
        let fixture = try FeatureFixture()
        defer { fixture.remove() }
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: fixture.runtime,
            subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
        )
        let allowlist: Set<String> = ["local.read"]

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
        let restrictedWithoutSession = await Self.toolNames(executor, ["local.read"], sessionID: nil)

        await fixture.runtime.exposeForTesting(FeatureFixture.featureID, sessionID: Self.coordinatorSessionID)

        #expect(await Self.toolNames(executor, nil, sessionID: Self.coordinatorSessionID) == unrestricted)
        #expect(await Self.toolNames(executor, ["local.read"], sessionID: nil) == restrictedWithoutSession)
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
        let allowlist: Set<String> = ["local.read"]
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

    // MARK: - Fixtures

    struct FeatureFixture {
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

    static func toolNames(
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

    static func toolCall(_ name: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: "\(name)-\(UUID().uuidString)", name: name, argumentsObject: [:], argumentsJSON: "{}")
    }
}
