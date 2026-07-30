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

    private struct AttachmentOutput: Codable, Sendable, FeatureInvocationAttachmentProviding {
        let value: String

        var featureInvocationAttachments: [FeatureInvocationAttachment] {
            [
                FeatureInvocationAttachment(
                    path: "/tmp/tool-image.png",
                    kind: .image,
                    contentType: "image/png",
                    originalFilename: "tool-image.png"
                )
            ]
        }
    }

    private struct AttachmentTool: FeatureTool {
        static let name = "sample.attachment"
        static let description = "Returns model-facing media."
        static let inputSchema = "{}"
        static let presentation = ToolPresentationDefinition(
            title: "Attachment",
            action: "Capture",
            kind: .read
        )

        func run(_ input: Input, context _: FeatureContext) async throws -> AttachmentOutput {
            AttachmentOutput(value: input.path ?? "ok")
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
    func invocationAttachmentsFlowThroughTypeErasedFeatureTool() async throws {
        let tool = AnyFeatureTool(AttachmentTool())

        let result = try await tool.invokeResult(
            inputData: Data("{}".utf8),
            context: FeatureContext(environment: [:])
        )
        let output = try JSONDecoder().decode(AttachmentOutput.self, from: result.outputData)
        let attachment = try #require(result.attachments.first)

        #expect(output.value == "ok")
        #expect(result.attachments.count == 1)
        #expect(attachment.path == "/tmp/tool-image.png")
        #expect(attachment.kind == .image)
        #expect(attachment.contentType == "image/png")
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
