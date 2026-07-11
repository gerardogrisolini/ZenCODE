import Foundation
import Testing
import ToolCore

@Suite
struct ToolDescriptorContractTests {
    @Test
    func encodingExcludesRuntimeIdentityAndPreservesDescriptorFields() throws {
        let descriptor = ToolDescriptor(
            name: "local.readFile",
            title: "Read file",
            description: "Reads a UTF-8 file.",
            inputSchema: #"{"type":"object"}"#,
            outputSchema: #"{"type":"string"}"#
        )

        let encoded = try JSONEncoder().encode(descriptor)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let fields = try #require(value.objectValue)

        #expect(fields["id"] == nil)
        #expect(fields["name"] == .string("local.readFile"))
        #expect(fields["title"] == .string("Read file"))
        #expect(fields["description"] == .string("Reads a UTF-8 file."))
        #expect(fields["inputSchema"] == .string(#"{"type":"object"}"#))
        #expect(fields["outputSchema"] == .string(#"{"type":"string"}"#))
    }

    @Test
    func canonicalizationOrdersByDescriptorFieldsAfterName() {
        let tools = [
            ToolDescriptor(name: "beta", description: "B", inputSchema: "{}"),
            ToolDescriptor(name: "alpha", title: "Zulu", description: "A", inputSchema: "{}"),
            ToolDescriptor(name: "alpha", title: "Alpha", description: "Z", inputSchema: "{}"),
            ToolDescriptor(name: "alpha", title: "Alpha", description: "A", inputSchema: "{}")
        ]

        let canonical = ToolDescriptor.canonicalized(tools)

        #expect(canonical.map(\.name) == ["alpha", "alpha", "alpha", "beta"])
        #expect(canonical.map(\.title) == ["Alpha", "Alpha", "Zulu", nil])
        #expect(canonical.map(\.description) == ["A", "Z", "A", "B"])
    }
}
