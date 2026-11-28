import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
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
        let output = try await runtime.executeResultIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "feature-collision",
                name: "feature.collision",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )?.output

        #expect(descriptors.count == 1)
        #expect(descriptors.first?.presentation == firstDefinition)
        #expect(output == "first-feature")
    }

}
