import Foundation
import Testing
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
    func compactRenderingUsesToolOwnedActionAndTarget() {
        let lines = TerminalChat.compactToolLines(
            for: Self.call(),
            statusIcon: "⏳",
            columnWidth: 80
        )

        #expect(lines.count == 2)
        #expect(lines[0] == "🛠️  Edit:")
        #expect(lines[1].contains("/tmp/App.swift"))
        #expect(lines[1].hasSuffix("⏳"))
    }

    @Test
    func detailedRenderingMapsSemanticElementsToExistingRowPrimitives() {
        let call = Self.call()
        let started = TerminalChat.detailedToolCallStartedLines(for: call)
        let completed = TerminalChat.detailedToolCallCompletedLines(
            for: call,
            result: DirectAgentToolResult(
                output: "changed",
                summary: "one replacement\nignored"
            ),
            contentWidth: 100
        )

        #expect(started.prefix(4) == [
            "🛠️  Source file",
            "kind: edit",
            "action: Edit",
            "target: /tmp/App.swift"
        ])
        #expect(started.contains("mode: replace"))
        #expect(started.contains("parameters:"))
        #expect(started.contains("change:"))
        #expect(started.last == "status: ⏳")
        #expect(completed.contains("summary: one replacement"))
        #expect(completed.last == "status: ✅")
        #expect(TerminalChat.codeLanguageHint(for: call) == "swift")
    }

    @Test
    func failureStatusAndErrorRemainOwnedByTUI() {
        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: Self.call(),
            result: DirectAgentToolResult(
                output: "Tool error: denied",
                summary: "denied",
                status: .permissionDenied
            ),
            contentWidth: 100
        )

        #expect(lines.contains("error:"))
        #expect(lines.contains("  Tool error: denied"))
        #expect(lines.last == "status: ⚠️")
    }

    @Test
    func toolProvidedMetadataCannotInjectTerminalControlsOrBidi() {
        let escape = "\u{1B}[31m"
        let bidi = "\u{202E}"
        let definition = ToolPresentationDefinition(
            title: "Unsafe\(escape)\(bidi) title",
            action: "Run\nnow",
            kind: .execute,
            target: .literal("target\r\nnext\u{0007}")
        )
        let call = DirectAgentToolCall(
            id: "unsafe",
            name: "thirdparty.unsafe",
            argumentsObject: [:],
            argumentsJSON: "{}",
            presentation: definition
        )

        let compact = TerminalChat.compactToolLines(
            for: call,
            statusIcon: "⏳",
            columnWidth: 100
        )
        let detailed = TerminalChat.detailedToolCallStartedLines(for: call)
        let rendered = (compact + detailed).joined(separator: "\n")

        #expect(!rendered.contains("\u{1B}"))
        #expect(!rendered.contains("\u{202E}"))
        #expect(!rendered.contains("\u{0007}"))
        #expect(!rendered.contains("\r"))
    }

    @Test
    func acpFacadeUsesSemanticTitleAndKindWhileKeepingLegacyNameAPI() throws {
        let call = Self.call()
        let update = ZenCODEACPBridge.toolCallCreateJSONUpdate(for: call)
        let object = try #require(update.objectValue)

        #expect(object["title"] == .string("Edit /tmp/App.swift"))
        #expect(object["kind"] == .string("edit"))
        #expect(ZenCODEACPBridge.toolKind(for: "unknown.tool") == "other")
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
        #expect(fallback.presentation == .automatic)
    }
}
