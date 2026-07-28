import Foundation
import Testing
import ToolCore

@Suite
struct ToolPresentationDefinitionTests {
    @Test
    func semanticDefinitionRoundTripsAllElementKinds() throws {
        let definition = ToolPresentationDefinition(
            title: "Source file",
            action: "Edit",
            kind: .edit,
            target: .argument(["path", "file_path"], format: .path),
            metadata: [
                ToolPresentationMetadataDefinition(
                    label: "mode",
                    value: .argument(["replaceAll", "replace_all"], format: .text)
                )
            ],
            sections: [
                .parameters(),
                .code(
                    label: "content",
                    value: .argument(["content"], format: .text),
                    languageHint: .literal("swift")
                ),
                .diff(
                    label: "change",
                    old: .argument(["oldString", "old_string"], format: .text),
                    new: .argument(["newString", "new_string"], format: .text),
                    languageHint: .argument(["path"], format: .path)
                ),
                .list(
                    label: "edits",
                    value: .argument(["edits"], format: .json)
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )

        let encoded = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(
            ToolPresentationDefinition.self,
            from: encoded
        )

        #expect(decoded == definition)
        #expect(decoded.isSemanticallyValid)
        #expect(decoded.sections.map(\.kind) == [.parameters, .code, .diff, .list])
        #expect(Set(decoded.summary?.modes ?? []) == [.compact, .expanded])
    }

    @Test
    func descriptorWithoutPresentationPreservesHistoricalShape() throws {
        let descriptor = ToolDescriptor(
            name: "legacy.tool",
            description: "Legacy descriptor.",
            inputSchema: "{}"
        )

        let encoded = try JSONEncoder().encode(descriptor)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let fields = try #require(value.objectValue)

        #expect(fields["presentation"] == nil)
        #expect(descriptor.presentation == nil)
    }

    @Test
    func explicitDescriptorPresentationRoundTrips() throws {
        let presentation = ToolPresentationDefinition(
            title: "File",
            action: "Read",
            kind: .read,
            target: .argument(["path"], format: .path),
            sections: [.parameters()]
        )
        let descriptor = ToolDescriptor(
            name: "local.readFile",
            description: "Reads a file.",
            inputSchema: "{}",
            presentation: presentation
        )

        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ToolDescriptor.self, from: encoded)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(decoded.presentation == presentation)
        #expect(value.objectValue?["presentation"] != nil)
    }

    @Test
    func missingOrMalformedPresentationDoesNotLoseDescriptor() throws {
        let legacy = Data(#"{"name":"legacy","description":"D","inputSchema":"{}"}"#.utf8)
        let malformed = Data(
            #"{"name":"future","description":"D","inputSchema":"{}","presentation":{"strategy":"future"}}"#.utf8
        )

        let legacyDescriptor = try JSONDecoder().decode(ToolDescriptor.self, from: legacy)
        let malformedDescriptor = try JSONDecoder().decode(ToolDescriptor.self, from: malformed)

        #expect(legacyDescriptor.presentation == nil)
        #expect(malformedDescriptor.name == "future")
        #expect(malformedDescriptor.presentation == nil)
    }

    @Test
    func presentationDoesNotChangePromptDescriptionsOrCanonicalOrdering() {
        let sentinel = "PRESENTATION_ONLY_SENTINEL"
        let presented = ToolDescriptor(
            name: "alpha",
            description: "A",
            inputSchema: "{}",
            presentation: ToolPresentationDefinition(
                title: sentinel,
                action: "Inspect",
                kind: .inspect
            )
        )
        let unpresented = ToolDescriptor(
            name: "beta",
            description: "B",
            inputSchema: "{}"
        )

        #expect(!presented.promptDescription().contains(sentinel))
        #expect(!presented.compactPromptDescription().contains(sentinel))
        #expect(!presented.toolCallDescription().contains(sentinel))
        #expect(ToolDescriptor.canonicalized([unpresented, presented]).map(\.name) == ["alpha", "beta"])
    }
}
