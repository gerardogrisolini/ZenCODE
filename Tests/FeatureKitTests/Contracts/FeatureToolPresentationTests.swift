import FeatureKit
import Foundation
import Testing
import ToolCore

@Suite
struct FeatureToolPresentationTests {
    private struct Input: Codable, Sendable {
        let path: String?
    }

    private struct DefaultPresentationTool: FeatureTool {
        static let name = "sample.default"
        static let description = "Uses the compatibility default."
        static let inputSchema = "{}"

        func run(_ input: Input, context: FeatureContext) async throws -> String {
            input.path ?? context.workingDirectory.path
        }
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
    func featureToolDefaultRemainsAutomaticAndOmittedFromListToolsWire() throws {
        let descriptor = AnyFeatureTool(DefaultPresentationTool()).descriptor
        let response = FeatureListToolsResponse(tools: [descriptor])
        let data = try JSONEncoder().encode(response)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(root["tools"] as? [[String: Any]])
        let tool = try #require(tools.first)

        #expect(descriptor.presentation == .automatic)
        #expect(tool["presentation"] == nil)
        #expect(tool["name"] as? String == "sample.default")
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
        #expect(presentation["strategy"] as? String == "semantic")
        #expect(presentation["action"] as? String == "Read")
    }

    @Test
    func malformedFeatureDescriptorPresentationFallsBackToAutomatic() throws {
        let data = Data(
            #"{"name":"sample.future","description":"D","inputSchema":"{}","presentation":{"strategy":"future"}}"#.utf8
        )

        let descriptor = try JSONDecoder().decode(FeatureToolDescriptor.self, from: data)

        #expect(descriptor.name == "sample.future")
        #expect(descriptor.presentation == .automatic)
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

        let feature = FeatureToolDescriptor(toolDescriptor: original)
        let roundTrip = feature.toolDescriptor

        #expect(feature.presentation == original.presentation)
        #expect(roundTrip.presentation == original.presentation)
        #expect(roundTrip.outputSchema == original.outputSchema)
    }
}
