import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ToolPresentationResolverTests {
    @Test
    func resolvesSemanticElementsWithoutTerminalFormatting() throws {
        let definition = ToolPresentationDefinition(
            title: "Source file",
            action: "Edit",
            kind: .edit,
            target: .argument(["path", "file_path"], format: .path),
            metadata: [
                ToolPresentationMetadataDefinition(
                    label: "mode",
                    value: .argument(["replaceAll", "replace_all"])
                )
            ],
            sections: [
                .parameters(),
                .code(
                    label: "new source",
                    value: .argument(["newString"], format: .text),
                    languageHint: .argument(["path"], format: .languageHint)
                ),
                .diff(
                    label: "change",
                    old: .argument(["oldString"], format: .text),
                    new: .argument(["newString"], format: .text),
                    languageHint: .argument(["path"], format: .languageHint)
                ),
                .list(
                    label: "items",
                    value: .argument(["items"], format: .json)
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )
        let call = DirectAgentToolCall(
            id: "resolve",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/App.swift",
                "oldString": "let old = 1",
                "newString": "let new = 2",
                "replaceAll": true,
                "items": ["one", "two"]
            ],
            argumentsJSON: "{}",
            descriptorTitle: "Ignored descriptor title",
            presentation: definition
        )
        let result = DirectAgentToolResult(
            output: "changed",
            summary: "1 replacement\nextra"
        )

        let resolved = ToolPresentationResolver.resolve(
            call: call,
            result: result,
            mode: .expanded
        )

        #expect(resolved.title == "Source file")
        #expect(resolved.action == "Edit")
        #expect(resolved.target == "/tmp/App.swift")
        #expect(resolved.kind == .edit)
        #expect(resolved.metadata == [ToolPresentationMetadata(label: "mode", value: "true")])
        #expect(!resolved.usesAutomaticFallback)
        #expect(resolved.elements.count == 5)

        guard case let .parameters(label, value) = resolved.elements[0] else {
            Issue.record("Expected parameters element")
            return
        }
        #expect(label == "parameters")
        #expect(value.objectValue?["path"] == .string("/tmp/App.swift"))

        guard case let .code(codeLabel, content, language) = resolved.elements[1] else {
            Issue.record("Expected code element")
            return
        }
        #expect(codeLabel == "new source")
        #expect(content == "let new = 2")
        #expect(language == "swift")

        guard case let .diff(diffLabel, old, new, diffLanguage) = resolved.elements[2] else {
            Issue.record("Expected diff element")
            return
        }
        #expect(diffLabel == "change")
        #expect(old == "let old = 1")
        #expect(new == "let new = 2")
        #expect(diffLanguage == "swift")

        guard case let .summary(summaryLabel, text) = resolved.elements[4] else {
            Issue.record("Expected summary element")
            return
        }
        #expect(summaryLabel == "summary")
        #expect(text == "1 replacement")
    }

    @Test
    func automaticFallbackIsGenericAndSafeForUnknownTools() throws {
        let call = DirectAgentToolCall(
            id: "unknown",
            name: "thirdparty.arbitrary",
            argumentsObject: ["query": "value"],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "output", summary: "done")

        let compact = ToolPresentationResolver.resolve(
            call: call,
            result: result,
            mode: .compact
        )
        let expanded = ToolPresentationResolver.resolve(
            call: call,
            result: result,
            mode: .expanded
        )

        #expect(compact.title == "thirdparty.arbitrary")
        #expect(compact.kind == .other)
        #expect(compact.usesAutomaticFallback)
        #expect(compact.elements == [.summary(label: "summary", text: "done")])
        #expect(expanded.usesAutomaticFallback)
        #expect(expanded.elements.count == 2)
        guard case let .parameters(_, parameters) = expanded.elements[0] else {
            Issue.record("Expected generic parameters")
            return
        }
        #expect(parameters.objectValue?["query"] == .string("value"))
    }

    @Test
    func remoteCatalogAttachesDescriptorMetadataBeforeEventsWithoutSendingItToModel() throws {
        let sentinel = "PRESENTATION_RUNTIME_ONLY_SENTINEL"
        let definition = ToolPresentationDefinition(
            title: sentinel,
            action: "Run",
            kind: .execute,
            target: .argument(["command"], format: .command)
        )
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}}}"#,
                    title: "Command",
                    presentation: definition
                )
            ]
        )
        let parsedCall = DirectAgentToolCall(
            id: "call",
            name: "tool_local_exec",
            argumentsObject: ["command": "pwd"],
            argumentsJSON: "{}"
        )

        let localCall = catalog.localToolCall(from: parsedCall)
        let sameNameCall = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "same-name",
                name: "local.exec",
                argumentsObject: ["command": "pwd"],
                argumentsJSON: "{}"
            )
        )
        let responsesPayload = JSONValue(jsonObject: catalog.responsesToolPayloads).prettyPrinted()
        let chatPayload = JSONValue(jsonObject: catalog.chatCompletionToolPayloads).prettyPrinted()

        #expect(localCall.name == "local.exec")
        #expect(localCall.descriptorTitle == "Command")
        #expect(localCall.presentation == definition)
        #expect(sameNameCall.presentation == definition)
        #expect(!responsesPayload.contains(sentinel))
        #expect(!chatPayload.contains(sentinel))
    }

    @Test
    func persistedRuntimeToolCallShapeDoesNotContainPresentation() throws {
        let call = DirectAgentToolCall(
            id: "persisted",
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/file"],
            argumentsJSON: "{}",
            descriptorTitle: "Runtime title",
            presentation: ToolPresentationDefinition(
                title: "Runtime only",
                action: "Read",
                kind: .read
            )
        )
        let persisted = AgentRuntimeToolCall(
            id: call.id,
            name: call.name,
            argumentsJSON: call.argumentsJSON
        )
        let data = try JSONEncoder().encode(persisted)
        let fields = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(fields.keys) == ["id", "name", "argumentsJSON"])
        #expect(fields["presentation"] == nil)
        #expect(fields["descriptorTitle"] == nil)
    }
}
