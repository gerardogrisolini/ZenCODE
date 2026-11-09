import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalSemanticToolRenderingTests {
    private static let definition = ToolPresentationDefinition(
        title: "Source file",
        action: "Edit",
        kind: .edit,
        target: .argument(["path"], format: .path),
        metadata: [
            ToolPresentationMetadataDefinition(
                label: "mode",
                value: .argument(["mode"])
            )
        ],
        sections: [
            .parameters(),
            .diff(
                label: "change",
                old: .argument(["old"], format: .text),
                new: .argument(["new"], format: .text),
                languageHint: .argument(["path"], format: .languageHint)
            )
        ],
        summary: ToolPresentationSummaryDefinition(
            value: .resultSummary(),
            strategy: .firstLine,
            label: "summary"
        )
    )

    private static func call(
        definition: ToolPresentationDefinition = definition
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "semantic",
            name: "thirdparty.edit",
            argumentsObject: [
                "path": "/tmp/App.swift",
                "mode": "replace",
                "old": "let old = 1",
                "new": "let new = 2"
            ],
            argumentsJSON: "{}",
            descriptorTitle: "Descriptor title",
            presentation: definition
        )
    }

    @Test
    func compactRenderingUsesCanonicalNameAndTarget() {
        let lines = TerminalChat.compactToolLines(
            for: Self.call(),
            statusIcon: "⏳",
            columnWidth: 80
        )

        #expect(lines == ["🛠️  thirdparty.edit", "/tmp/App.swift ⏳"])
    }

    @Test
    func compactInspectUsesItsSafeArgumentAsTarget() {
        let call = DirectAgentToolCall(
            id: "inspect",
            name: "thirdparty.inspect",
            argumentsObject: ["identifier": "node-42"],
            argumentsJSON: #"{"identifier":"node-42"}"#,
            presentation: ToolPresentationDefinition(
                title: "Third-party resource",
                action: "Inspect",
                kind: .inspect
            )
        )

        let lines = TerminalChat.compactToolLines(
            for: call,
            statusIcon: "✅",
            statusDetail: "0.03s",
            columnWidth: 80
        )

        #expect(lines == ["🛠️  thirdparty.inspect", "node-42 ✅ 0.03s"])
    }

    @Test
    func compactFileListInspectAndWriteShowTheirCanonicalNameAndPathArgument() throws {
        let cases: [(String, [String: Any], String, String, String)] = [
            (
                "local.ls",
                ["path": "Sources", "includeHidden": false],
                "List",
                "Sources",
                "0.03s"
            ),
            (
                "local.inspectFile",
                ["file_path": "Sources/App.swift"],
                "Inspect",
                "Sources/App.swift",
                "0.47s"
            ),
            (
                "local.writeFile",
                ["path": "Sources/App.swift", "content": "struct App {}"],
                "Write",
                "Sources/App.swift",
                "0.01s"
            )
        ]

        for (name, arguments, _, path, duration) in cases {
            let descriptor = try #require(
                DirectToolCatalog.coreLocalFileAndTextDescriptors.first { $0.name == name }
            )
            let call = DirectAgentToolCall(
                id: name,
                name: name,
                argumentsObject: arguments,
                argumentsJSON: "{}",
                descriptorTitle: descriptor.title,
                presentation: descriptor.presentation
            )

            #expect(ToolCallPresentation.displayToolTarget(for: call) == path)
            #expect(
                TerminalChat.compactToolLines(
                    for: call,
                    statusIcon: "✅",
                    statusDetail: duration,
                    columnWidth: 100
                ) == [
                    "🛠️  \(name)",
                    "\(path) ✅ \(duration)"
                ]
            )
        }
    }

    @Test
    func acpFacadeUsesSemanticTitleAndKindWhileKeepingLegacyNameAPI() throws {
        let call = Self.call()
        let update = ZenCODEACPBridge.toolCallCreateJSONUpdate(for: call)
        let object = try #require(update.objectValue)

        #expect(object["title"] == .string("thirdparty.edit /tmp/App.swift"))
        #expect(object["kind"] == .string("edit"))
    }

    @Test
    func replayReappliesCurrentDescriptorWithoutPersistingPresentation() {
        let persisted = AgentRuntimeToolCall(
            id: "restored",
            name: "thirdparty.edit",
            argumentsJSON: #"{"path":"/tmp/App.swift","old":"a","new":"b"}"#
        )
        let descriptor = DirectToolDescriptor(
            name: "thirdparty.edit",
            description: "Edit a third-party resource.",
            inputSchema: "{}",
            title: "Current descriptor",
            presentation: Self.definition
        )

        let restored = TerminalChat.directToolCall(
            from: persisted,
            descriptor: descriptor
        )
        let fallback = TerminalChat.directToolCall(from: persisted)

        #expect(restored.presentation == Self.definition)
        #expect(restored.descriptorTitle == "Current descriptor")
        #expect(restored.argumentsObject["path"] as? String == "/tmp/App.swift")
        #expect(fallback.presentation == nil)
    }
}
