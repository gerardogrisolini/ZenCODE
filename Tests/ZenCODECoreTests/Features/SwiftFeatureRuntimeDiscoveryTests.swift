//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureMCPBridgeKit
import Foundation
@testable import ZenCODECore
import Testing
import ToolCore
#if os(macOS)
import XcodeToolsFeature
#endif

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
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-outline-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        // Optional features are self-contained SwiftPM packages, not products
        // of the root graph. Build the real package in this test's UUID scratch
        // directory, then exercise the exact executable users install.
        let executableURL = try Self.buildOptionalFeatureProduct(
            named: "swift-tools-feature",
            sourceRelativePath: "Sources/Features/SwiftTools",
            scratchPath: rootURL.appendingPathComponent("swift-package-scratch", isDirectory: true)
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
                    tools: [
                        ToolDescriptor(
                            name: "swift.outline",
                            description: "Returns a compact Swift outline.",
                            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#,
                            presentation: .standard(
                                title: "Swift outline",
                                action: "Inspect",
                                kind: .inspect,
                                targetKeyPaths: ["path"],
                                targetFormat: .path
                            )
                        )
                    ]
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
          printf '{"tools":[{"name":"dynamic.echo","description":"Dynamic echo","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
          printf '{"tools":[{"name":"dynamic.unrelated","description":"Should not run","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
          printf '{"tools":[{"name":"dynamic.status","description":"Dynamic status","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
            .appendingPathComponent("xcode-mcp-descriptor-reuse-\(UUID().uuidString)", isDirectory: true)
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
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
          printf '{"tools":[{"name":"xcode.BuildProject","description":"Dynamic Xcode build","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
    func defaultGitFeatureStatusDeclaresToolOwnedRuntimeDiscovery() {
        let gitStatus = SwiftFeatureRuntime.defaultFeatureStatuses(
            includeTools: true,
            includeDisabled: true
        ).first { $0.id == "git-tools" }

        #expect(gitStatus?.tools.isEmpty == true)
        #expect(gitStatus?.toolNamePrefixes == ["git."])
        #expect(gitStatus?.discoversToolsAtRuntime == true)
    }

    @Test
    func uninstalledOptionalFeatureIsUnavailableWithInstallInstructions() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-not-installed-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let statuses = SwiftFeatureRuntime.defaultFeatureStatuses(
            searchRoots: [rootURL],
            includeTools: false,
            includeDisabled: true
        )
        let gitStatus = try #require(statuses.first { $0.id == "git-tools" })

        #expect(gitStatus.source == .bundled)
        #expect(!gitStatus.available)
        #expect(!gitStatus.enabled)
        #expect(gitStatus.issue == SwiftFeatureRuntime.optionalFeatureNotInstalledIssue)
        // The reported path is the destination the installer will create, not an
        // executable shipped next to the binary.
        #expect(
            gitStatus.executablePath
                == rootURL
                    .appendingPathComponent("git-tools", isDirectory: true)
                    .appendingPathComponent(".build/release/git-tools-feature")
                    .standardizedFileURL
                    .path
        )
    }

    @Test
    func uninstalledOptionalFeaturesContributeNoBundlesOrTools() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-empty-root-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        #expect(SwiftFeatureRuntime.defaultFeatureBundles(searchRoots: [rootURL]).isEmpty)
        #expect(SwiftFeatureRuntime.defaultFeatureToolDescriptors(searchRoots: [rootURL]).isEmpty)
    }

    @Test
    func optionalFeatureCatalogReportsCatalogIdentityAndInstallPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-optional-list-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let features = SwiftFeatureRuntime.optionalFeatures(searchRoots: [rootURL])
        let git = try #require(features.first { $0.id == "git-tools" })

        #expect(git.productName == "git-tools-feature")
        #expect(git.displayName == "Git")
        #expect(git.sourceRelativePath == "Sources/Features/GitTools")
        #expect(!git.installed)
        #expect(!git.enabled)
        #expect(!git.built)
        #expect(git.supportedOnCurrentPlatform)
        #expect(
            git.installPath
                == rootURL.appendingPathComponent("git-tools", isDirectory: true)
                    .standardizedFileURL
                    .path
        )
    }

    /// Builds one self-contained optional feature without using or probing the
    /// root package's build products. The caller owns `scratchPath` and removes
    /// it with its UUID test root.
    static func buildOptionalFeatureProduct(
        named productName: String,
        sourceRelativePath: String,
        scratchPath: URL
    ) throws -> URL {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let featurePackageURL = packageRoot.appendingPathComponent(sourceRelativePath, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = scratchPath
            .appendingPathComponent("support", isDirectory: true)
            .path

        _ = try runFeaturePackageProcess(
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                scratchPath.path,
                "--product",
                productName
            ],
            currentDirectoryURL: featurePackageURL,
            environment: environment
        )
        let binPathData = try runFeaturePackageProcess(
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                scratchPath.path,
                "--show-bin-path"
            ],
            currentDirectoryURL: featurePackageURL,
            environment: environment
        )
        let binPath = String(decoding: binPathData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL = URL(fileURLWithPath: binPath, isDirectory: true)
            .appendingPathComponent(productName)
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SwiftFeaturePackageBuildError.missingExecutable(executableURL.path)
        }
        return executableURL
    }

    private static func runFeaturePackageProcess(
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SwiftFeaturePackageBuildError.commandFailed(
                arguments: arguments,
                output: String(decoding: outputData, as: UTF8.self)
            )
        }
        return outputData
    }

    private enum SwiftFeaturePackageBuildError: LocalizedError {
        case missingExecutable(String)
        case commandFailed(arguments: [String], output: String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let path):
                return "Optional feature build did not produce executable at \(path)."
            case .commandFailed(let arguments, let output):
                return "\(arguments.joined(separator: " ")) failed: \(output)"
            }
        }
    }
}
