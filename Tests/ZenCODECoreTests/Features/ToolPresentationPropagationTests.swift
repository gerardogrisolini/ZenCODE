import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ToolPresentationPropagationTests {
    private static func presentation(
        title: String,
        action: String = "Read"
    ) -> ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: title,
            action: action,
            kind: .read,
            target: .argument(["path", "file_path"], format: .path),
            sections: [.parameters()]
        )
    }

    @Test
    func manifestAndDirectDescriptorBridgesPreservePresentation() throws {
        let definition = Self.presentation(title: "Manifest file")
        let original = ToolDescriptor(
            name: "manifest.read",
            title: "Manifest title",
            description: "Reads a manifest fixture.",
            inputSchema: #"{"type":"object"}"#,
            outputSchema: #"{"type":"string"}"#,
            presentation: definition
        )

        let manifest = try JSONDecoder().decode(
            SwiftFeatureToolManifest.self,
            from: JSONEncoder().encode(original)
        )
        let direct = DirectToolDescriptor(toolDescriptor: manifest.toolDescriptor)
        let roundTrip = direct.toolDescriptor

        #expect(manifest.presentation == definition)
        #expect(direct.presentation == definition)
        #expect(direct.title == original.title)
        #expect(direct.outputSchema == original.outputSchema)
        #expect(roundTrip.presentation == definition)

        let encodedManifest = try JSONEncoder().encode(manifest)
        let encodedValue = try JSONDecoder().decode(JSONValue.self, from: encodedManifest)
        #expect(encodedValue.objectValue?["presentation"] != nil)
    }

    @Test
    func malformedManifestPresentationFallsBackWithoutRejectingTool() throws {
        let manifest = try JSONDecoder().decode(
            SwiftFeatureToolManifest.self,
            from: Data(
                #"{"name":"manifest.future","description":"D","inputSchema":"{}","presentation":{"strategy":"future"}}"#.utf8
            )
        )

        #expect(manifest.name == "manifest.future")
        #expect(manifest.presentation == .automatic)
        #expect(manifest.toolDescriptor.presentation == .automatic)
    }

    @Test
    func runtimeDiscoveryPreservesValidPresentationAndIgnoresInvalidPresentation() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-presentation-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("feature")
        try #"""
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          cat <<'JSON'
        {"tools":[{"name":"dynamic.presented","description":"Presented","inputSchema":"{}","presentation":{"strategy":"semantic","title":"Dynamic file","action":"Read","kind":"read","target":{"source":"arguments","keyPaths":["path"],"format":"path"},"metadata":[],"sections":[]}},{"name":"dynamic.future","description":"Future","inputSchema":"{}","presentation":{"strategy":"future"}}]}
        JSON
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"done"}\n'
        """#.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-presentation",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let descriptors = await runtime.descriptors()
        let presented = try #require(descriptors.first { $0.name == "dynamic.presented" })
        let future = try #require(descriptors.first { $0.name == "dynamic.future" })

        #expect(presented.presentation.title == "Dynamic file")
        #expect(presented.presentation.target?.keyPaths == ["path"])
        #expect(future.presentation == .automatic)
    }

    @Test
    func providerRegistryDescriptorUsesSameFirstProviderAsExecutor() async throws {
        let firstDefinition = Self.presentation(title: "First provider")
        let secondDefinition = Self.presentation(title: "Second provider")
        let first = AgentToolProvider(
            tools: [
                ToolDescriptor(
                    name: "provider.collision",
                    description: "First descriptor",
                    inputSchema: "{}",
                    presentation: firstDefinition
                )
            ],
            executor: { _ in "first-provider" }
        )
        let second = AgentToolProvider(
            tools: [
                ToolDescriptor(
                    name: "provider.collision",
                    description: "Second descriptor",
                    inputSchema: "{}",
                    presentation: secondDefinition
                )
            ],
            executor: { _ in "second-provider" }
        )
        var registry = AgentToolProviderRegistry()
        registry.update([first, second])

        let descriptor = try #require(registry.descriptors.first)
        let selectedExecutor = try #require(registry.executor(for: "provider.collision"))
        let output = try await selectedExecutor(
            AgentToolCall(id: "collision", name: "provider.collision", argumentsJSON: "{}")
        )

        #expect(registry.descriptors.count == 1)
        #expect(descriptor.presentation == firstDefinition)
        #expect(output == "first-provider")
    }

    @Test
    func providerDescriptorPrecedesFeatureManagementWhenProviderExecutesName() async throws {
        let definition = Self.presentation(title: "Provider feature list")
        let provider = AgentToolProvider(
            tools: [
                ToolDescriptor(
                    name: "feature.list",
                    description: "Session provider override.",
                    inputSchema: "{}",
                    presentation: definition
                )
            ],
            executor: { _ in "provider-feature-list" }
        )
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        await executor.updateToolProviders([provider], sessionID: "presentation-session")

        let descriptors = await executor.descriptors(
            allowedToolNames: ["feature.list"],
            sessionID: "presentation-session"
        )
        let descriptor = try #require(descriptors.first)
        let result = await executor.execute(
            sessionID: "presentation-session",
            toolCall: DirectAgentToolCall(
                id: "provider-feature-list",
                name: "feature.list",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["feature.list"]
        )

        #expect(descriptors.count == 1)
        #expect(descriptor.presentation == definition)
        #expect(result.output == "provider-feature-list")
        #expect(result.status == .completed)
        await executor.shutdown()
    }

    @Test
    func firstSwiftFeatureOwnsBothDuplicateDescriptorAndExecution() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-presentation-feature-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        func writeExecutable(named name: String, output: String) throws -> URL {
            let url = rootURL.appendingPathComponent(name)
            try """
            #!/bin/sh
            cat >/dev/null
            printf '{"ok":true,"output":"\(output)"}\\n'
            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
            return url
        }

        let firstURL = try writeExecutable(named: "first", output: "first-feature")
        let secondURL = try writeExecutable(named: "second", output: "second-feature")
        let firstDefinition = Self.presentation(title: "First feature")
        let secondDefinition = Self.presentation(title: "Second feature")
        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "first",
                    executableURL: firstURL,
                    tools: [
                        ToolDescriptor(
                            name: "feature.collision",
                            description: "First",
                            inputSchema: "{}",
                            presentation: firstDefinition
                        )
                    ]
                ),
                SwiftFeatureBundle(
                    id: "second",
                    executableURL: secondURL,
                    tools: [
                        ToolDescriptor(
                            name: "feature.collision",
                            description: "Second",
                            inputSchema: "{}",
                            presentation: secondDefinition
                        )
                    ]
                )
            ]
        )

        let descriptors = await runtime.descriptors()
        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "feature-collision",
                name: "feature.collision",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )

        #expect(descriptors.count == 1)
        #expect(descriptors.first?.presentation == firstDefinition)
        #expect(output == "first-feature")
    }

    @Test
    func laterRelevantFeatureDoesNotPublishDescriptorOwnedByEarlierFeature() async {
        let collision = ToolDescriptor(
            name: "feature.collision",
            description: "Collision",
            inputSchema: "{}"
        )
        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "first",
                    executableURL: URL(fileURLWithPath: "/tmp/first-feature"),
                    tools: [collision],
                    toolNameAliases: ["first.only"]
                ),
                SwiftFeatureBundle(
                    id: "second",
                    executableURL: URL(fileURLWithPath: "/tmp/second-feature"),
                    tools: [collision],
                    toolNameAliases: ["second.only"]
                )
            ]
        )

        let descriptors = await runtime.descriptors(
            allowedToolNames: ["second.only"]
        )
        let isAllowed = await runtime.featureToolIsAllowed(
            toolName: collision.name,
            allowedToolNames: ["second.only"]
        )

        #expect(descriptors.isEmpty)
        #expect(!isAllowed)
    }

    @Test
    func featureScopedAllowlistDoesNotDispatchProviderCollision() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-presentation-source-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-owner"}\\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let featurePresentation = Self.presentation(title: "Feature owner")
        let featureRuntime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "feature-owner",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "collision.run",
                            description: "Feature descriptor",
                            inputSchema: "{}",
                            presentation: featurePresentation
                        )
                    ],
                    toolNameAliases: ["feature.only"]
                )
            ]
        )
        let provider = AgentToolProvider(
            tools: [
                ToolDescriptor(
                    name: "collision.run",
                    description: "Provider descriptor",
                    inputSchema: "{}",
                    presentation: Self.presentation(title: "Provider owner")
                )
            ],
            executor: { _ in "provider-owner" }
        )
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: featureRuntime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        await executor.updateToolProviders([provider], sessionID: "collision-session")

        let descriptors = await executor.descriptors(
            allowedToolNames: ["feature.only"],
            sessionID: "collision-session"
        )
        let result = await executor.execute(
            sessionID: "collision-session",
            toolCall: DirectAgentToolCall(
                id: "collision",
                name: "collision.run",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL,
            allowedToolNames: ["feature.only"]
        )

        #expect(descriptors.map(\.name) == ["collision.run"])
        #expect(descriptors.first?.presentation == featurePresentation)
        #expect(result.output == "feature-owner")
        #expect(result.status == .completed)
        await executor.shutdown()
    }

    @Test
    func knownMCPFamiliesGetProviderPresentationWhileArbitraryServersStayAutomatic() {
        let descriptor = ToolDescriptor(
            name: "inspect",
            title: "Inspect selection",
            description: "Inspect a remote selection.",
            inputSchema: "{}"
        )

        let xcode = DirectMCPToolRuntime.presentation(
            for: descriptor,
            family: .xcode
        )
        let figma = DirectMCPToolRuntime.presentation(
            for: descriptor,
            family: .figma
        )
        let external = DirectMCPToolRuntime.presentation(
            for: descriptor,
            family: .external("third-party")
        )

        #expect(!xcode.isAutomatic)
        #expect(!figma.isAutomatic)
        #expect(external.isAutomatic)
    }
}
