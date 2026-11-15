//
//  DirectToolExecutorFeatureBuildExposureTests.swift
//  ZenCODE
//
//  The Builder exposure end to end: `DirectToolExecutor.execute` ->
//  `dispatchFeatureManagement` -> `SwiftFeatureRuntime.executeManagementTool`
//  -> registration, for `feature.build`, `feature.scaffold`, and
//  `feature.install`, with the real validation and reload and a fake
//  `swift build` (the `featureBuildExecutor` seam). Covers who registers
//  (only a delegated Builder), what registers (a generated, non-catalog
//  feature under the generated features root, rebuilt features included),
//  and the delegated namespace check, which refuses before anything is
//  written or built while the same call made without a Builder identity is
//  unchanged.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectToolExecutorFeatureBuildExposureTests {
    private static let coordinatorSessionID = "coordinator-session"
    private static let builderSessionID = "builder-agent_session"
    private static let refusal = "cannot be built by a delegated Builder"

    // MARK: - Who registers

    @Test
    func featureBuildThroughABuilderExecutorExposesTheFeatureToTheDelegatingSession() async throws {
        try await Workspace.with { workspace in
            try await workspace.scaffold(id: "changelog-fixture", toolName: "changelog.build", enabled: true)
            let builder = workspace.builderExecutor()
            let coordinator = workspace.coordinatorExecutor()
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID).isEmpty)

            let result = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.build", ["id": "changelog-fixture"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )

            #expect(result.status == .completed, "\(result.output)")
            let report = try JSONDecoder().decode(SwiftFeatureBuildReport.self, from: Data(result.output.utf8))
            #expect(report.ok)
            #expect(await workspace.builds.featureIDs == ["changelog-fixture"])
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID)
                == ["changelog-fixture"])
            // The builder's own session and any other session see nothing.
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.builderSessionID).isEmpty)
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: "other-session").isEmpty)

            // The coordinator lists and runs the tool it never selected.
            let names = await coordinator.descriptors(
                allowedToolNames: ["local.readFile"],
                sessionID: Self.coordinatorSessionID,
                discoversFeatureTools: false
            ).map(\.name)
            #expect(names.contains("changelog.build"))
            let run = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: Self.call("changelog.build", ["text": "x"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["local.readFile"]
            )
            #expect(run.status == .completed, "\(run.output)")
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    @Test
    func theSameBuildWithoutABuilderIdentityRegistersNothing() async throws {
        try await Workspace.with { workspace in
            try await workspace.scaffold(id: "plain-fixture", toolName: "plain.run", enabled: true)
            let executors = [
                // The operator's own session, or a Builder used directly.
                workspace.coordinatorExecutor(),
                workspace.coordinatorExecutor(profileRole: .builder),
                // A delegated sub-agent with another role.
                workspace.delegatedExecutor(profileRole: .developer),
            ]

            for executor in executors {
                let result = await executor.execute(
                    sessionID: Self.coordinatorSessionID,
                    toolCall: Self.call("feature.build", ["id": "plain-fixture"]),
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(result.status == .completed, "\(result.output)")
                await executor.shutdown()
            }

            #expect(await workspace.builds.featureIDs == Array(repeating: "plain-fixture", count: 3))
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
        }
    }

    @Test
    func scaffoldAndInstallThatBuildThroughABuilderExecutorExposeTheFeature() async throws {
        try await Workspace.with { workspace in
            let builder = workspace.builderExecutor()

            let scaffold = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.scaffold", [
                    "id": "scaffolded-fixture",
                    "toolName": "scaffolded.run",
                    "build": true,
                    "enable": true,
                ]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(scaffold.status == .completed, "\(scaffold.output)")

            let sourceURL = try await workspace.scaffoldElsewhere(id: "installed-fixture", toolName: "installed.run")
            let install = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.install", ["path": sourceURL.path]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(install.status == .completed, "\(install.output)")

            #expect(await workspace.builds.featureIDs == ["scaffolded-fixture", "installed-fixture"])
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID)
                == ["scaffolded-fixture", "installed-fixture"])
            await builder.shutdown()
        }
    }

    // MARK: - What registers

    @Test
    func aBuilderBuildOfACatalogIDOrOfAManifestOutsideTheRootRegistersNothing() async throws {
        try await Workspace.with { workspace in
            let catalogID = try #require(
                SwiftFeatureRuntime.bundledFeatureDefinitions().first { !$0.isCore }?.id
            )
            // A local copy that keeps the catalog ID, under the features root.
            try await workspace.scaffold(id: catalogID, toolName: "catalogcopy.run", enabled: true)
            // A package prepared outside the features root.
            let outsideURL = try await workspace.scaffoldElsewhere(id: "outside-fixture", toolName: "outside.run")
            let builder = workspace.builderExecutor()

            for arguments: [String: Any] in [
                ["id": catalogID],
                ["manifestPath": outsideURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename).path],
            ] {
                let result = await builder.execute(
                    sessionID: Self.builderSessionID,
                    toolCall: Self.call("feature.build", arguments),
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(result.status == .completed, "\(result.output)")
            }

            #expect(await workspace.builds.featureIDs == [catalogID, "outside-fixture"])
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID).isEmpty)
            await builder.shutdown()
        }
    }

    /// The reuse case: a generated feature that already exists, rebuilt by
    /// the delegated Builder, is exposed like a new one.
    @Test
    func aPreexistingGeneratedFeatureRebuiltByTheBuilderIsExposed() async throws {
        try await Workspace.with { workspace in
            try await workspace.scaffold(id: "reused-fixture", toolName: "reused.run", enabled: true)
            let coordinator = workspace.coordinatorExecutor()
            _ = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: Self.call("feature.build", ["id": "reused-fixture"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            // Loaded, built by the operator: not exposed.
            #expect(await workspace.runtime.features.contains { $0.id == "reused-fixture" })
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID).isEmpty)

            let builder = workspace.builderExecutor()
            let rebuild = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.build", ["id": "reused-fixture"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )

            #expect(rebuild.status == .completed, "\(rebuild.output)")
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID)
                == ["reused-fixture"])
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    // MARK: - Delegated namespace

    @Test
    func aBuilderIsRefusedACoreNamespaceBeforeAnythingIsWrittenOrBuilt() async throws {
        try await Workspace.with { workspace in
            let builder = workspace.builderExecutor()
            let coordinator = workspace.coordinatorExecutor()
            let scaffoldCall = Self.call("feature.scaffold", ["id": "tasks-export", "toolName": "tasks.exportCSV"])
            let packageURL = workspace.featuresURL.appendingPathComponent("tasks-export", isDirectory: true)

            let refusedScaffold = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: scaffoldCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refusedScaffold.status != .completed)
            #expect(refusedScaffold.output.contains(Self.refusal), "\(refusedScaffold.output)")
            #expect(refusedScaffold.output.contains("'tasks.'"), "\(refusedScaffold.output)")
            #expect(refusedScaffold.output.contains("Give the feature a namespace of its own."))
            #expect(!FileManager.default.fileExists(atPath: packageURL.path))
            #expect(Self.stagingEntries(in: workspace.featuresURL).isEmpty)

            // Without a Builder identity the same scaffold is unchanged.
            let scaffold = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: scaffoldCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(scaffold.status == .completed, "\(scaffold.output)")
            #expect(FileManager.default.fileExists(atPath: packageURL.path))

            // A build of that package: refused for the Builder before the
            // build runs, unchanged for the coordinator.
            let buildCall = Self.call("feature.build", ["id": "tasks-export"])
            let refusedBuild = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: buildCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refusedBuild.status != .completed)
            #expect(refusedBuild.output.contains(Self.refusal), "\(refusedBuild.output)")
            #expect(await workspace.builds.featureIDs.isEmpty)
            let build = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: buildCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(build.status == .completed, "\(build.output)")
            #expect(await workspace.builds.featureIDs == ["tasks-export"])

            // An install whose manifest takes `memory.`: refused before the copy.
            let sourceURL = try await workspace.scaffoldElsewhere(id: "memory-export", toolName: "memory.export")
            let refusedInstall = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.install", ["path": sourceURL.path]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refusedInstall.status != .completed)
            #expect(refusedInstall.output.contains(Self.refusal), "\(refusedInstall.output)")
            #expect(!FileManager.default.fileExists(
                atPath: workspace.featuresURL.appendingPathComponent("memory-export").path
            ))
            #expect(await workspace.builds.featureIDs == ["tasks-export"])
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    @Test
    func aBuilderIsRefusedTheNamespaceOfAnotherLoadedFeature() async throws {
        try await Workspace.with { workspace in
            let coordinator = workspace.coordinatorExecutor()
            try await workspace.scaffold(id: "owner-fixture", toolName: "owned.run", enabled: true)
            _ = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: Self.call("feature.build", ["id": "owner-fixture"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(await workspace.runtime.features.contains { $0.id == "owner-fixture" })
            try await workspace.scaffold(id: "intruder-build", toolName: "owned.other", enabled: true)
            let builder = workspace.builderExecutor()

            let refusedScaffold = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.scaffold", ["id": "intruder", "toolName": "owned.extra"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refusedScaffold.status != .completed)
            #expect(refusedScaffold.output.contains(Self.refusal), "\(refusedScaffold.output)")
            #expect(refusedScaffold.output.contains("'owner-fixture'"), "\(refusedScaffold.output)")
            #expect(!FileManager.default.fileExists(
                atPath: workspace.featuresURL.appendingPathComponent("intruder").path
            ))

            let refusedBuild = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.build", ["id": "intruder-build"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refusedBuild.status != .completed)
            #expect(refusedBuild.output.contains("'owner-fixture'"), "\(refusedBuild.output)")
            #expect(await workspace.builds.featureIDs == ["owner-fixture"])
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)

            // The owner itself, rebuilt by the Builder, is not its own rival.
            let rebuild = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.build", ["id": "owner-fixture"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(rebuild.status == .completed, "\(rebuild.output)")
            #expect(await workspace.runtime.exposedFeatureIDs(sessionID: Self.coordinatorSessionID)
                == ["owner-fixture"])
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    /// A name under a core namespace (`local.readFile.pdf`, `skills.list.x`),
    /// whose derived prefix a session allowing the core tool would find
    /// relevant, is refused for the Builder before the scaffold writes or the
    /// build runs; the same calls without a Builder identity are unchanged.
    @Test
    func aBuilderIsRefusedANameUnderACoreNamespaceBeforeAnythingIsWrittenOrBuilt() async throws {
        try await Workspace.with { workspace in
            let builder = workspace.builderExecutor()
            let coordinator = workspace.coordinatorExecutor()
            var builtFeatureIDs: [String] = []
            for (id, toolName, namespace) in [
                ("pdf-reader", "local.readFile.pdf", "local."),
                ("skills-extra", "skills.list.x", "skills."),
            ] {
                let scaffoldCall = Self.call("feature.scaffold", ["id": id, "toolName": toolName])
                let packageURL = workspace.featuresURL.appendingPathComponent(id, isDirectory: true)

                let refusedScaffold = await builder.execute(
                    sessionID: Self.builderSessionID,
                    toolCall: scaffoldCall,
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(refusedScaffold.status != .completed)
                #expect(refusedScaffold.output.contains(Self.refusal), "\(refusedScaffold.output)")
                #expect(refusedScaffold.output.contains(
                    "its tool '\(toolName)' falls in the namespace '\(namespace)' of the core tools"
                ), "\(refusedScaffold.output)")
                #expect(!FileManager.default.fileExists(atPath: packageURL.path))
                #expect(Self.stagingEntries(in: workspace.featuresURL).isEmpty)

                let scaffold = await coordinator.execute(
                    sessionID: Self.coordinatorSessionID,
                    toolCall: scaffoldCall,
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(scaffold.status == .completed, "\(scaffold.output)")
                #expect(FileManager.default.fileExists(atPath: packageURL.path))

                let buildCall = Self.call("feature.build", ["id": id])
                let refusedBuild = await builder.execute(
                    sessionID: Self.builderSessionID,
                    toolCall: buildCall,
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(refusedBuild.status != .completed)
                #expect(refusedBuild.output.contains(Self.refusal), "\(refusedBuild.output)")
                #expect(await workspace.builds.featureIDs == builtFeatureIDs)

                let build = await coordinator.execute(
                    sessionID: Self.coordinatorSessionID,
                    toolCall: buildCall,
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(build.status == .completed, "\(build.output)")
                builtFeatureIDs.append(id)
                #expect(await workspace.builds.featureIDs == builtFeatureIDs)
            }
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    /// `feature.enable` by the Builder checks the manifest it would enable:
    /// a manifest that takes a core namespace is refused and stays disabled,
    /// while the same enable without a Builder identity is unchanged, and a
    /// namespace of its own is enabled.
    @Test
    func aBuilderEnableOfAManifestOutsideItsNamespaceIsRefusedBeforeEnabling() async throws {
        try await Workspace.with { workspace in
            try await workspace.scaffold(id: "pdf-enable", toolName: "local.readFile.pdf", enabled: false)
            try await workspace.scaffold(id: "own-enable", toolName: "ownenable.run", enabled: false)
            let coordinator = workspace.coordinatorExecutor()
            for id in ["pdf-enable", "own-enable"] {
                let build = await coordinator.execute(
                    sessionID: Self.coordinatorSessionID,
                    toolCall: Self.call("feature.build", ["id": id]),
                    workingDirectory: workspace.featuresURL,
                    allowedToolNames: ["feature."]
                )
                #expect(build.status == .completed, "\(build.output)")
            }
            let builder = workspace.builderExecutor()
            let enableCall = Self.call("feature.enable", ["id": "pdf-enable"])

            let refused = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: enableCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(refused.status != .completed)
            #expect(refused.output.contains("Feature 'pdf-enable' cannot be enabled by a delegated Builder"),
                    "\(refused.output)")
            #expect(refused.output.contains("falls in the namespace 'local.' of the core tools"), "\(refused.output)")
            let record = try #require(SwiftFeatureRegistry.featureRecord(
                id: "pdf-enable",
                searchRoots: [workspace.featuresURL],
                fileManager: .default
            ))
            #expect(!record.manifestEnabled)
            #expect(await !workspace.runtime.features.contains { $0.id == "pdf-enable" })

            let ownEnable = await builder.execute(
                sessionID: Self.builderSessionID,
                toolCall: Self.call("feature.enable", ["id": "own-enable"]),
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(ownEnable.status == .completed, "\(ownEnable.output)")
            #expect(await workspace.runtime.features.contains { $0.id == "own-enable" })

            let enable = await coordinator.execute(
                sessionID: Self.coordinatorSessionID,
                toolCall: enableCall,
                workingDirectory: workspace.featuresURL,
                allowedToolNames: ["feature."]
            )
            #expect(enable.status == .completed, "\(enable.output)")
            #expect(await workspace.runtime.features.contains { $0.id == "pdf-enable" })
            #expect(await workspace.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            await builder.shutdown()
            await coordinator.shutdown()
        }
    }

    // MARK: - Fixtures

    /// Feature IDs the fake build ran for, in order.
    actor BuildLog {
        private(set) var featureIDs: [String] = []

        func append(_ featureID: String) {
            featureIDs.append(featureID)
        }
    }

    /// A throwaway support directory, a generated features root, and a
    /// runtime over that root whose `swift build` is a fake one that writes
    /// the expected executable.
    private struct Workspace {
        let rootURL: URL
        let featuresURL: URL
        let runtime: SwiftFeatureRuntime
        let builds: BuildLog

        static func with(_ body: (Workspace) async throws -> Void) async throws {
            let rootURL = try SwiftFeatureSessionExposureTests.temporaryDirectory("feature-build-exposure")
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let supportURL = rootURL.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try await AppStorageDirectory.withSupportDirectoryURL(supportURL) {
                let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
                let builds = BuildLog()
                let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
                await runtime.setFeatureBuildExecutor(Self.fakeBuild(logging: builds))
                try await body(Workspace(
                    rootURL: rootURL,
                    featuresURL: featuresURL,
                    runtime: runtime,
                    builds: builds
                ))
            }
        }

        static func fakeBuild(logging builds: BuildLog) -> SwiftFeatureBuildExecutor {
            { invocation in
                await builds.append(invocation.featureID)
                try SwiftFeatureSessionExposureTests.writeExecutable(at: invocation.executableURL)
                return SwiftFeatureBuildReport(
                    ok: true,
                    id: invocation.featureID,
                    command: ["swift"] + invocation.commandArguments,
                    workingDirectory: invocation.packageDirectoryURL.path,
                    executablePath: invocation.executableURL.path,
                    exitCode: 0,
                    timedOut: false,
                    stdout: "",
                    stderr: ""
                )
            }
        }

        /// Scaffolds a package under the features root, as the operator would.
        func scaffold(id: String, toolName: String, enabled: Bool) async throws {
            _ = try await runtime.executeManagementTool(
                toolCall: DirectToolExecutorFeatureBuildExposureTests.call("feature.scaffold", [
                    "id": id,
                    "toolName": toolName,
                    "enabled": enabled,
                ])
            )
        }

        /// Scaffolds a package outside the features root and returns its
        /// directory.
        func scaffoldElsewhere(id: String, toolName: String) async throws -> URL {
            let elsewhereURL = rootURL.appendingPathComponent("elsewhere-\(UUID().uuidString)", isDirectory: true)
            let elsewhere = SwiftFeatureRuntime(featureSearchRoots: [elsewhereURL])
            _ = try await elsewhere.executeManagementTool(
                toolCall: DirectToolExecutorFeatureBuildExposureTests.call("feature.scaffold", [
                    "id": id,
                    "toolName": toolName,
                ])
            )
            return elsewhereURL.appendingPathComponent(id, isDirectory: true)
        }

        /// The executor of a Builder sub-agent that the coordinator session
        /// delegated.
        func builderExecutor() -> DirectToolExecutor {
            delegatedExecutor(profileRole: .builder)
        }

        func delegatedExecutor(profileRole: AgentProfileRole) -> DirectToolExecutor {
            DirectToolExecutor(
                swiftFeatureRuntime: runtime,
                sharedChatSenderID: "builder-agent",
                sharedChatRootSessionID: DirectToolExecutorFeatureBuildExposureTests.coordinatorSessionID,
                toolExecutionContext: ToolExecutionContext(
                    profileRole: profileRole,
                    isSubAgent: true,
                    delegatingSessionID: DirectToolExecutorFeatureBuildExposureTests.coordinatorSessionID
                ),
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )
        }

        /// A top-level executor, with no delegation identity.
        func coordinatorExecutor(profileRole: AgentProfileRole? = nil) -> DirectToolExecutor {
            DirectToolExecutor(
                swiftFeatureRuntime: runtime,
                toolExecutionContext: ToolExecutionContext(profileRole: profileRole),
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )
        }
    }

    static func call(_ name: String, _ arguments: [String: Any]) -> DirectAgentToolCall {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: "\(name)-\(UUID().uuidString)",
            name: name,
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }

    /// The scaffold staging directories left in `directoryURL`.
    private static func stagingEntries(in directoryURL: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? [])
            .filter { $0.hasPrefix(".zencode-feature-") }
    }
}
