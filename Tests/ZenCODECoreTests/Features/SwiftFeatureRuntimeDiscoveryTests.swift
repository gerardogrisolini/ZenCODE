//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension SwiftFeatureRuntimeTests {
    @Test
    func runtimeExecutesFeatureProcess() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-runtime-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "feature.fixture.echo",
                            description: "Echo fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ]
                )
            ]
        )
        let toolCall = DirectAgentToolCall(
            id: "feature-call-1",
            name: "feature.fixture.echo",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        let output = try await runtime.executeIfAvailable(
            toolCall: toolCall,
            workingDirectory: rootURL
        )

        #expect(output == "feature-output")
    }

    @Test
    func runtimeHonorsFeatureInvocationTimeoutOverride() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-timeout-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "timeout-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "feature.timeout.wait",
                            description: "Wait fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ],
                    invocationTimeoutSeconds: 0.2
                )
            ]
        )

        await #expect(throws: (any Error).self) {
            _ = try await runtime.executeIfAvailable(
                toolCall: DirectAgentToolCall(
                    id: "timeout-call-1",
                    name: "feature.timeout.wait",
                    argumentsObject: [:],
                    argumentsJSON: "{}"
                ),
                workingDirectory: rootURL
            )
        }
    }

    @Test
    func bundledFeatureToolsUseAppropriateInvocationTimeouts() throws {
        let records = SwiftFeatureRuntime.defaultFeatureRecords(
            searchRoots: nil,
            fileManager: .default
        )

        let swiftDefinition = try #require(
            SwiftFeatureRuntime.bundledFeatureDefinition(id: "swift-tools")
        )
        let swiftRecord = try #require(records.first { $0.id == "swift-tools" })
        let webRecord = try #require(records.first { $0.id == "web-tools" })
        let xcodeRecord = try #require(records.first { $0.id == "xcode-tools" })
        let gitRecord = try #require(records.first { $0.id == "git-tools" })

        #expect(swiftDefinition.invocationTimeoutSeconds == 3_660)
        #expect(swiftRecord.invocationTimeoutSeconds == swiftDefinition.invocationTimeoutSeconds)
        #expect(webRecord.invocationTimeoutSeconds == 180)
        #expect(xcodeRecord.invocationTimeoutSeconds == 3_660)
        #expect(gitRecord.invocationTimeoutSeconds == nil)
    }

    @Test
    func bundledSwiftOutlineReturnsCompactDeclarationMap() async throws {
        let status = try #require(
            SwiftFeatureRuntime.defaultFeatureStatuses()
                .first { $0.id == "swift-tools" }
        )
        let executablePath = status.executablePath
        let executableURL = URL(fileURLWithPath: executablePath)
        try #require(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-outline-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appendingPathComponent("Feature.swift")
        try """
        import Foundation

        // MARK: Feature
        struct Feature {
            let title: String

            func render() {}
        }

        extension Feature {
            class func make() -> Feature {
                Feature(title: "demo")
            }
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "swift-tools",
                    executableURL: executableURL,
                    tools: DirectToolCatalog.swiftDescriptors.map(\.toolDescriptor)
                )
            ]
        )
        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "swift-outline-call",
                name: "swift.outline",
                argumentsObject: ["path": "Feature.swift"],
                argumentsJSON: #"{"path":"Feature.swift"}"#
            ),
            workingDirectory: rootURL
        )

        let rendered = try #require(output)
        #expect(rendered.contains("File: \(sourceURL.path)"))
        #expect(rendered.contains("read_hint: local.readFile"))
        #expect(rendered.contains("mark\tFeature"))
        #expect(rendered.contains("struct\tFeature"))
        #expect(rendered.contains("let\tFeature.title"))
        #expect(rendered.contains("func\tFeature.render"))
        #expect(rendered.contains("extension\tFeature"))
        #expect(rendered.contains("func\tFeature.make"))
    }

    @Test
    func runtimeDiscoversDynamicFeatureToolsOnlyWhenRelevant() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-dynamic-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("list-tools-marker")
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"dynamic.echo","description":"Dynamic echo","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"dynamic-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-fixture",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        // When allowedToolNames is nil, all features are relevant and runtime
        // discovery should occur (consistent with the filtered case).
        let allDescriptors = await runtime.descriptors()
        #expect(allDescriptors.map(\.name) == ["dynamic.echo"])
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        // An unrelated filter must not make the feature relevant — its discovery
        // is skipped entirely. A fresh runtime with a separate marker file is
        // used to avoid any cache interaction and to prove the subprocess was
        // never invoked.
        let unrelatedMarkerURL = rootURL.appendingPathComponent("unrelated-list-tools-marker")
        let unrelatedExecutableURL = rootURL.appendingPathComponent("unrelated-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(unrelatedMarkerURL.path)"
          printf '{"tools":[{"name":"dynamic.unrelated","description":"Should not run","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"unrelated"}\n'
        """.write(to: unrelatedExecutableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unrelatedExecutableURL.path
        )
        let unrelatedRuntime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-fixture-unrelated",
                    executableURL: unrelatedExecutableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let unrelatedDescriptors = await unrelatedRuntime.descriptors(
            allowedToolNames: ["other."]
        )
        #expect(unrelatedDescriptors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unrelatedMarkerURL.path))

        let relatedDescriptors = await runtime.descriptors(
            allowedToolNames: ["dynamic."]
        )
        #expect(relatedDescriptors.map(\.name) == ["dynamic.echo"])

        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "dynamic-call-1",
                name: "dynamic.echo",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )
        #expect(output == "dynamic-output")
    }

    @Test
    func featureStatusesDoNotDiscoverRuntimeToolsByDefault() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-status-no-discovery-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("list-tools-marker")
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"dynamic.status","description":"Dynamic status","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"status-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "status-fixture",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        let statuses = await runtime.featureStatuses(includeTools: true)

        #expect(statuses.first?.id == "status-fixture")
        #expect(statuses.first?.tools == [])
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func directMCPRuntimeDoesNotAutodiscoverExternalConnectorsByDefault() async {
        let runtime = DirectMCPToolRuntime()

        let descriptors = await runtime.descriptors(
            allowedToolNames: ["xcode.", "figma."]
        )

        #expect(descriptors.isEmpty)
    }

    @Test
    func directToolExecutorDiscoversXcodeThroughSwiftFeatureRuntimeAsFallback() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-feature-discovery-fallback-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("xcode-feature-discovered")
        let executableURL = rootURL.appendingPathComponent("xcode-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"feature-xcode-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "xcode-tools",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    toolNameAliases: ["BuildProject"],
                    discoversToolsAtRuntime: true,
                    source: .bundled
                )
            ]
        )
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )

        // Without MCP providing xcode descriptors, the Swift feature runtime
        // serves as a fallback and discovers the tools at runtime.
        let descriptors = await executor.descriptors(
            allowedToolNames: ["xcode."]
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func directToolExecutorUsesExistingMCPXcodeDescriptorsWithoutFeatureDiscovery() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-xcode-mcp-descriptor-reuse-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("xcode-feature-discovered")
        let executableURL = rootURL.appendingPathComponent("xcode-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"feature-xcode-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "xcode-tools",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    toolNameAliases: ["BuildProject"],
                    discoversToolsAtRuntime: true,
                    source: .bundled
                )
            ]
        )
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        await mcpRuntime.installBorrowedXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ]
        )
        let executor = DirectToolExecutor(
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )

        let descriptors = await executor.descriptors(
            allowedToolNames: ["xcode."]
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func subagentInheritsXcodeFallbackFromParentRuntime() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-subagent-inherit-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("xcode-feature-discovered")
        let executableURL = rootURL.appendingPathComponent("xcode-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"feature-xcode-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let parentRuntime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "xcode-tools",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    toolNameAliases: ["BuildProject"],
                    discoversToolsAtRuntime: true,
                    source: .bundled
                )
            ]
        )

        // The sub-agent backend factory receives the BackendContext with the
        // parent's swiftFeatureRuntime injected by DirectToolExecutor.init.
        // We verify that a DirectToolExecutor built with the same runtime
        // (simulating the sub-agent's executor) produces the same xcode
        // descriptors via the shared cache — without re-running discovery.
        let parentExecutor = DirectToolExecutor(
            swiftFeatureRuntime: parentRuntime,
            preferredWorkspaceRootURL: rootURL,
            subAgentContextualBackendFactory: { _ in
                SwiftFeatureTestAgentRuntimeBackend()
            }
        )

        // Simulate the descriptor query the parent would make.
        let parentDescriptors = await parentExecutor.descriptors(
            allowedToolNames: ["xcode."]
        )
        #expect(parentDescriptors.map(\.name) == ["xcode.BuildProject"])

        // The parent executor injected its swiftFeatureRuntime into the context.
        // We verify this by checking that a DirectToolExecutor built with the
        // captured runtime (simulating the sub-agent's executor) produces the
        // same xcode descriptors via the shared cache — without re-running
        // discovery.
        let markerSizeBefore = (try? FileManager.default.attributesOfItem(atPath: markerURL.path)[.size] as? Int) ?? 0
        let subExecutor = DirectToolExecutor(
            swiftFeatureRuntime: parentRuntime,
            preferredWorkspaceRootURL: rootURL,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let subDescriptors = await subExecutor.descriptors(
            allowedToolNames: ["xcode."]
        )
        let markerSizeAfter = (try? FileManager.default.attributesOfItem(atPath: markerURL.path)[.size] as? Int) ?? 0

        #expect(subDescriptors.map(\.name) == ["xcode.BuildProject"])
        // The shared runtime cache means no additional --list-tools subprocess.
        #expect(markerSizeAfter == markerSizeBefore)
    }

    @Test
    func xcodeFallbackActivatesWhenMcpWorkspaceDoesNotMatch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-workspace-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("xcode-feature-discovered")
        let executableURL = rootURL.appendingPathComponent("xcode-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}"}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"feature-xcode-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "xcode-tools",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    toolNameAliases: ["BuildProject"],
                    discoversToolsAtRuntime: true,
                    source: .bundled
                )
            ]
        )

        // Install an Xcode executor whose workspace matches a DIFFERENT root.
        // When descriptors() is called with rootURL as preferredWorkspaceRootURL,
        // MCP's serverMatchesPreferredWorkspace will return false (workspace
        // mismatch), so MCP won't provide xcode descriptors.
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        let differentWorkspace = URL(fileURLWithPath: "/tmp/different-workspace-\(UUID().uuidString)")
        _ = await mcpRuntime.installXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ],
            workspaceContexts: [
                XcodeWorkspaceContext(
                    workspacePath: differentWorkspace.path,
                    defaultTabIdentifier: nil
                )
            ],
            preferredWorkspaceRootURL: differentWorkspace,
            ownsExecutor: false
        )

        let executor = DirectToolExecutor(
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: runtime,
            preferredWorkspaceRootURL: rootURL,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )

        // MCP workspace doesn't match → MCP provides no xcode descriptors.
        // The feature runtime should sub in as fallback.
        let descriptors = await executor.descriptors(
            allowedToolNames: ["xcode."]
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func defaultFeatureStatusesIncludeBundledPackagesEvenWhenManaged() {
        let statuses = SwiftFeatureRuntime.defaultFeatureStatuses(
            includeTools: false,
            includeDisabled: true
        )
        let ids = Set(statuses.map(\.id))

        #expect(ids.contains("search-tools"))
        #expect(ids.contains("web-tools"))
        #expect(ids.contains("git-tools"))
        #expect(ids.contains("swift-tools"))
        #expect(ids.contains("xcode-tools"))
        #expect(ids.contains("figma-tools"))
        #expect(statuses.filter { $0.source == .bundled }.allSatisfy { !$0.isCore })
        #expect(statuses.filter { $0.source == .bundled }.allSatisfy { $0.adoptable })
    }

    @Test
    func defaultGitFeatureStatusIncludesPushTool() {
        let gitStatus = SwiftFeatureRuntime.defaultFeatureStatuses(
            includeTools: true,
            includeDisabled: true
        ).first { $0.id == "git-tools" }

        #expect(gitStatus?.tools.contains("git.commit") == true)
        #expect(gitStatus?.tools.contains("git.push") == true)
    }

    @Test
    func bundledExecutableCandidatesIncludeSourcePackageBuildProductsFromOtherWorkingDirectory() throws {
        let outsideWorkingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-cwd-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: outsideWorkingDirectory)
        }
        try FileManager.default.createDirectory(
            at: outsideWorkingDirectory,
            withIntermediateDirectories: true
        )
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let packageBuildPrefix = packageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .path + "/"

        let candidates = SwiftFeatureRuntime.bundledExecutableCandidateURLs(
            named: "git-tools-feature",
            fileManager: .default,
            workingDirectoryURL: outsideWorkingDirectory
        )

        #expect(
            candidates.contains {
                $0.path.hasPrefix(packageBuildPrefix)
                    && $0.lastPathComponent == "git-tools-feature"
            }
        )
    }

    @Test
    func bundledExecutableCandidatesIncludeReleaseFeaturesDirectoryNextToBinary() throws {
        let binaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-release-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: binaryDirectoryURL)
        }
        try FileManager.default.createDirectory(
            at: binaryDirectoryURL,
            withIntermediateDirectories: true
        )

        let candidates = SwiftFeatureRuntime.bundledExecutableCandidateURLs(
            named: "web-tools-feature",
            fileManager: .default,
            pathEnvironment: nil,
            commandLineArgument: nil,
            executableDirectoryURLs: [binaryDirectoryURL]
        )
        let expectedURL = binaryDirectoryURL
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("web-tools-feature")
            .standardizedFileURL

        #expect(candidates.contains { $0.path == expectedURL.path })
    }

    @Test
    func bundledExecutableCandidatesIncludeInstallerFeatureDirectoryNextToBinary() throws {
        let binaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: binaryDirectoryURL)
        }
        try FileManager.default.createDirectory(
            at: binaryDirectoryURL,
            withIntermediateDirectories: true
        )

        let candidates = SwiftFeatureRuntime.bundledExecutableCandidateURLs(
            named: "git-tools-feature",
            fileManager: .default,
            pathEnvironment: nil,
            commandLineArgument: nil,
            executableDirectoryURLs: [binaryDirectoryURL]
        )
        let expectedURL = binaryDirectoryURL
            .appendingPathComponent("zen-features", isDirectory: true)
            .appendingPathComponent("git-tools-feature")
            .standardizedFileURL

        #expect(candidates.contains { $0.path == expectedURL.path })
    }

    @Test
    func bundledExecutableCandidatesResolveInvocationThroughPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-path-\(UUID().uuidString)", isDirectory: true)
        let binaryDirectoryURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: binaryDirectoryURL,
            withIntermediateDirectories: true
        )
        let coderURL = binaryDirectoryURL.appendingPathComponent("ZenCODE")
        try "#!/bin/sh\n".write(to: coderURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: coderURL.path
        )

        let candidates = SwiftFeatureRuntime.bundledExecutableCandidateURLs(
            named: "figma-tools-feature",
            fileManager: .default,
            pathEnvironment: binaryDirectoryURL.path,
            commandLineArgument: "ZenCODE"
        )
        let expectedURL = binaryDirectoryURL
            .appendingPathComponent("figma-tools-feature")
            .standardizedFileURL

        #expect(candidates.contains { $0.path == expectedURL.path })
    }
}
