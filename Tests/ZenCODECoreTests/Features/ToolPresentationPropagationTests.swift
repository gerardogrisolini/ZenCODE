import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

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
    func malformedManifestPresentationIsRejected() {
        let data = Data(
            #"{"name":"manifest.future","description":"D","inputSchema":"{}","presentation":{"strategy":"future"}}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SwiftFeatureToolManifest.self, from: data)
        }
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

}
