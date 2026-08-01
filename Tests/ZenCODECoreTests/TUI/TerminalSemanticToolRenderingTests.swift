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
    func compactListAndWriteUseTheirCanonicalNameAndSemanticSubject() throws {
        let listDescriptor = PromptSkillToolProvider.listToolDescriptor
        let writeDescriptor = try #require(
            DirectToolCatalog.memoryDescriptors.first { $0.name == "memory.write" }
        )
        let cases: [(DirectToolDescriptor, [String: Any], String, [String])] = [
            (
                listDescriptor,
                [:],
                "0.03s",
                ["🛠️  skills.list", "Prompt skills ✅ 0.03s"]
            ),
            (
                writeDescriptor,
                ["content": "Summary: completed"],
                "0.01s",
                ["🛠️  memory.write", "Project memory ✅ 0.01s"]
            )
        ]

        for (descriptor, arguments, duration, expectedLines) in cases {
            let call = DirectAgentToolCall(
                id: descriptor.name,
                name: descriptor.name,
                argumentsObject: arguments,
                argumentsJSON: "{}",
                descriptorTitle: descriptor.title,
                presentation: descriptor.presentation
            )

            let lines = TerminalChat.compactToolLines(
                for: call,
                statusIcon: "✅",
                statusDetail: duration,
                columnWidth: 100
            )

            #expect(lines == expectedLines)
        }
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
                DirectToolCatalog.filesystemDescriptors.first { $0.name == name }
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
    func compactTaskListUsesItsDeclaredStatusTarget() throws {
        let descriptor = try #require(
            DirectToolCatalog.todoTaskDescriptors.first { $0.name == "tasks.list" }
        )
        let call = DirectAgentToolCall(
            id: "task-list",
            name: descriptor.name,
            argumentsObject: [
                "status": "pending",
                "runnableOnly": true,
                "includeTerminal": false
            ],
            argumentsJSON: #"{"status":"pending","runnableOnly":true,"includeTerminal":false}"#,
            presentation: descriptor.presentation
        )

        let lines = TerminalChat.compactToolLines(
            for: call,
            statusIcon: "✅",
            statusDetail: "0.02s",
            columnWidth: 80
        )

        #expect(
            lines == ["🛠️  tasks.list", "pending ✅ 0.02s"]
        )
    }

    @Test
    func compactFeatureListUsesItsDeclaredBooleanTarget() throws {
        let descriptor = try #require(
            DirectToolCatalog.featureDescriptors.first { $0.name == "feature.list" }
        )
        let call = DirectAgentToolCall(
            id: "feature-list",
            name: descriptor.name,
            argumentsObject: ["includeTools": true],
            argumentsJSON: #"{"includeTools":true}"#,
            presentation: descriptor.presentation
        )

        let lines = TerminalChat.compactToolLines(
            for: call,
            statusIcon: "✅",
            statusDetail: "0.02s",
            columnWidth: 80
        )

        #expect(lines == ["🛠️  feature.list", "true ✅ 0.02s"])
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

        #expect(started.prefix(3) == [
            "🛠️  thirdparty.edit",
            "kind: edit",
            "action: Edit"
        ])
        #expect(!started.contains { $0.hasPrefix("target: ") })
        #expect(started.contains("kind: edit"))
        #expect(started.contains("mode: replace"))
        #expect(!started.contains("parameters:"))
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
