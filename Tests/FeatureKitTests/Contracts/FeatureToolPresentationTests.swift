import FeatureKit
import Foundation
import Testing
import ToolCore

@Suite
struct FeatureToolPresentationTests {
    private struct Input: Codable, Sendable {
        let path: String?
    }

    private struct ExplicitPresentationTool: FeatureTool {
        static let name = "sample.explicit"
        static let description = "Publishes semantic presentation metadata."
        static let inputSchema = "{}"
        static let presentation = ToolPresentationDefinition(
            title: "Sample",
            action: "Read",
            kind: .read,
            target: .argument(["path"], format: .path),
            sections: [.parameters()]
        )

        func run(_ input: Input, context: FeatureContext) async throws -> String {
            input.path ?? context.workingDirectory.path
        }
    }

    @Test
    func explicitPresentationFlowsThroughAnyFeatureToolAndListToolsWire() throws {
        let descriptor = AnyFeatureTool(ExplicitPresentationTool()).descriptor
        let response = FeatureListToolsResponse(tools: [descriptor])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FeatureListToolsResponse.self, from: data)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(root["tools"] as? [[String: Any]])
        let presentation = try #require(tools.first?["presentation"] as? [String: Any])

        #expect(descriptor.presentation == ExplicitPresentationTool.presentation)
        #expect(decoded.tools.first?.presentation == ExplicitPresentationTool.presentation)
        #expect(root["schemaVersion"] as? Int == FeatureListToolsResponse.currentSchemaVersion)
        #expect(presentation["strategy"] == nil)
        #expect(presentation["action"] as? String == "Read")
    }

    @Test
    func legacyListToolsMayOmitPresentationButCurrentSchemaMayNot() throws {
        let legacy = Data(
            #"{"tools":[{"name":"sample.legacy","description":"D","inputSchema":"{}"}]}"#.utf8
        )
        let current = Data(
            #"{"schemaVersion":2,"tools":[{"name":"sample.current","description":"D","inputSchema":"{}"}]}"#.utf8
        )

        let decodedLegacy = try JSONDecoder().decode(FeatureListToolsResponse.self, from: legacy)

        #expect(decodedLegacy.schemaVersion == 1)
        #expect(decodedLegacy.tools.first?.presentation == nil)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FeatureListToolsResponse.self, from: current)
        }
    }

    @Test
    func malformedFeatureDescriptorPresentationIsRejected() throws {
        let data = Data(
            #"{"name":"sample.future","description":"D","inputSchema":"{}","presentation":{"strategy":"future"}}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FeatureToolDescriptor.self, from: data)
        }
    }

    @Test
    func toolDescriptorBridgePreservesPresentation() {
        let original = ToolDescriptor(
            name: "sample.bridge",
            title: "Bridge title",
            description: "D",
            inputSchema: "{}",
            outputSchema: #"{"type":"string"}"#,
            presentation: ExplicitPresentationTool.presentation
        )

        let feature = FeatureToolDescriptor(
            toolDescriptor: original,
            presentation: ExplicitPresentationTool.presentation
        )
        let roundTrip = feature.toolDescriptor

        #expect(feature.presentation == original.presentation)
        #expect(roundTrip.presentation == original.presentation)
        #expect(roundTrip.outputSchema == original.outputSchema)
    }
}
