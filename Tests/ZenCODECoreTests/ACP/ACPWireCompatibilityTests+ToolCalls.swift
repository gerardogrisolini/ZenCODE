//
//  ACPWireCompatibilityTests+ToolCalls.swift
//  ZenCODE
//
//  Wire compatibility tests of the ACP tool-call updates: the v1 keys, the
//  complete create and completion payloads (standard `name` and `rawInput`
//  on the `tool_call`, the result once as `content`, no `_meta` copies, no
//  title on the completion), tool kinds, locations, and titles.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension ACPCompatibilityTests {
    @Test
    func toolCallUpdatesUseACPv1WireKeys() throws {
        let toolCall = presentedToolCall(
            id: "call_001",
            name: "local.exec",
            argumentsObject: [
                "command": "swift test",
                "workingDirectory": "/tmp/workspace"
            ],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"/tmp/workspace"}"#
        )

        let create = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall)
        #expect(create["sessionUpdate"] as? String == "tool_call")
        #expect(create["toolCallId"] as? String == "call_001")
        #expect(create["title"] as? String == "swift test")
        #expect(create["name"] as? String == "local.exec")
        #expect(create["status"] as? String == "pending")
        #expect(create["tool_call_id"] == nil)

        let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(
                output: "Build complete.",
                summary: "Build complete."
            )
        )
        #expect(completion["sessionUpdate"] as? String == "tool_call_update")
        #expect(completion["toolCallId"] as? String == "call_001")
        #expect(completion["title"] == nil)
        #expect(completion["status"] as? String == "completed")
    }

    @Test
    func toolCallCreatePreservesCompleteWirePayloadAndJSONWrapper() throws {
        let toolCall = presentedToolCall(
            id: "call_wire",
            name: "local.exec",
            argumentsObject: ["command": "swift test", "workingDirectory": "Sources"],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"Sources"}"#
        )
        let workspace = URL(fileURLWithPath: "/tmp/acp-workspace")
        let expected: JSONValue = .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("call_wire"),
            "name": .string("local.exec"),
            "title": .string("swift test"),
            "kind": .string("execute"),
            "status": .string("pending"),
            "content": .array([]),
            "locations": .array([.object(["path": .string("/tmp/acp-workspace/Sources")])]),
            "rawInput": .object([
                "command": .string("swift test"),
                "workingDirectory": .string("Sources"),
            ]),
        ])
        let update = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall, workingDirectory: workspace)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: update))
        #expect(decoded == expected)
        #expect(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall, workingDirectory: workspace) == expected)
    }

    @Test
    func toolCallCompletionPreservesCompleteWirePayloadAndJSONWrapper() throws {
        let toolCall = presentedToolCall(
            id: "call_wire",
            name: "local.exec",
            argumentsObject: ["command": "swift test", "workingDirectory": "Sources"],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"Sources"}"#
        )
        let workspace = URL(fileURLWithPath: "/tmp/acp-workspace")
        let cases: [(
            output: String,
            summary: String,
            status: DirectAgentToolResult.Status,
            wireStatus: String,
            fileChanges: [OperationFileChange],
            content: JSONValue?
        )] = [
            ("", "", .completed, "completed", [], nil),
            (" \n\t", "No output", .completed, "completed", [], nil),
            ("", "", .failed, "failed", [], nil),
            (" \n\t", "Denied", .permissionDenied, "failed", [], nil),
            (" Done.\n", "Success", .completed, "completed", [], .array([
                .object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string(" Done.\n"),
                ])]),
            ])),
            ("Failure details", "Failed", .failed, "failed", [], .array([
                .object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string("Failure details"),
                ])]),
            ])),
            ("Tool error: unavailable", "Error", .completed, "failed", [], .array([
                .object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string("Tool error: unavailable"),
                ])]),
            ])),
            (
                "output",
                "summary",
                .completed,
                "completed",
                [
                    .init(path: "/tmp/new.swift", oldText: nil, newText: "new"),
                    .init(
                        path: "/tmp/fallback.swift",
                        oldText: nil,
                        newText: nil,
                        explanation: "Diff unavailable"
                    ),
                    .init(path: "/tmp/old.swift", oldText: "old", newText: nil),
                ],
                .array([
                    .object(["type": .string("content"), "content": .object([
                        "type": .string("text"), "text": .string("summary\n\noutput"),
                    ])]),
                    .object([
                        "type": .string("diff"),
                        "path": .string("/tmp/new.swift"),
                        "oldText": .null,
                        "newText": .string("new"),
                    ]),
                    .object(["type": .string("content"), "content": .object([
                        "type": .string("text"),
                        "text": .string("/tmp/fallback.swift: Diff unavailable"),
                    ])]),
                    .object([
                        "type": .string("diff"),
                        "path": .string("/tmp/old.swift"),
                        "oldText": .string("old"),
                        "newText": .string(""),
                    ]),
                ])
            ),
            (
                "same",
                "same",
                .completed,
                "completed",
                [.init(path: "/tmp/fallback.swift", oldText: nil, newText: nil, explanation: "Diff unavailable")],
                .array([
                    .object(["type": .string("content"), "content": .object([
                        "type": .string("text"), "text": .string("same"),
                    ])]),
                    .object(["type": .string("content"), "content": .object([
                        "type": .string("text"),
                        "text": .string("/tmp/fallback.swift: Diff unavailable"),
                    ])]),
                ])
            ),
        ]
        for fixture in cases {
            let result = DirectAgentToolResult(
                output: fixture.output,
                summary: fixture.summary,
                modelOutput: "Not part of the ACP payload",
                status: fixture.status,
                fileChanges: fixture.fileChanges
            )
            var fields: [String: JSONValue] = [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("call_wire"),
                "kind": .string("execute"),
                "status": .string(fixture.wireStatus),
                "locations": .array(
                    (fixture.fileChanges.isEmpty
                        ? ["/tmp/acp-workspace/Sources"]
                        : fixture.fileChanges.map(\.path))
                        .map { .object(["path": .string($0)]) }
                ),
            ]
            fields["content"] = fixture.content
            let expected = JSONValue.object(fields)
            let update = ZenCODEACPBridge.toolCallCompletionUpdate(
                for: toolCall, result: result, workingDirectory: workspace
            )
            let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: update))
            #expect(decoded == expected)
            #expect(ZenCODEACPBridge.toolCallCompletionJSONUpdate(
                for: toolCall, result: result, workingDirectory: workspace
            ) == expected)
        }
    }

    @Test
    func completionLocationsIncludeEveryRecordedChangedFile() {
        let toolCall = presentedToolCall(
            id: "call_multi_file",
            name: "local.exec",
            argumentsObject: [
                "command": "swiftgen previews",
                "workingDirectory": "Sources"
            ],
            argumentsJSON: #"{"command":"swiftgen previews","workingDirectory":"Sources"}"#
        )
        let paths = (1...6).map { "/tmp/acp-workspace/Sources/Preview\($0).swift" }
        let changes = paths.map { path in
            OperationFileChange(path: path, oldText: "old\n", newText: "new\n")
        }

        let update = ZenCODEACPBridge.toolCallCompletionJSONUpdate(
            for: toolCall,
            result: DirectAgentToolResult(
                output: "updated six files",
                summary: "updated six files",
                fileChanges: changes
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/acp-workspace")
        )
        let locations = update.objectValue?["locations"]?.arrayValue?.compactMap {
            $0.objectValue?["path"]?.acpStringValue
        } ?? []
        let diffPaths = update.objectValue?["content"]?.arrayValue?.compactMap { content -> String? in
            guard content.objectValue?["type"] == .string("diff") else {
                return nil
            }
            return content.objectValue?["path"]?.acpStringValue
        } ?? []

        #expect(locations == paths)
        #expect(diffPaths == paths)
    }

    @Test
    func emptyToolResultsDoNotEmitEmptyContentBlocks() {
        let toolCall = presentedToolCall(
            id: "call_empty",
            name: "search.grep",
            argumentsObject: ["pattern": "missing"],
            argumentsJSON: #"{"pattern":"missing"}"#
        )

        let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(output: " \n", summary: "No matches")
        )

        #expect(completion["status"] as? String == "completed")
        #expect(completion["content"] == nil)
        #expect(completion["rawOutput"] == nil)
        #expect(completion["_meta"] == nil)
    }

    @Test
    func toolCallUpdatesOnlyUseProtocolToolKinds() {
        let acpToolKinds: Set<String> = [
            "read", "edit", "delete", "move", "search",
            "execute", "think", "fetch", "switch_mode", "other"
        ]
        let inspectToolCall = presentedToolCall(
            id: "call_inspect",
            name: "local.inspect",
            argumentsObject: ["path": "/tmp/workspace/alpha.swift"],
            argumentsJSON: #"{"path":"/tmp/workspace/alpha.swift"}"#
        )
        let directoryCreationToolCall = presentedToolCall(
            id: "call_mkdir",
            name: "local.mkdir",
            argumentsObject: ["path": "/tmp/workspace/new"],
            argumentsJSON: #"{"path":"/tmp/workspace/new"}"#
        )
        let taskCreationToolCall = presentedToolCall(
            id: "call_tasks",
            name: "tasks.create",
            argumentsObject: ["title": "Ship the fix"],
            argumentsJSON: #"{"title":"Ship the fix"}"#
        )
        let featureToolCall = presentedToolCall(
            id: "call_feature",
            name: "feature.enable",
            argumentsObject: ["id": "git-tools"],
            argumentsJSON: #"{"id":"git-tools"}"#
        )

        #expect(ZenCODEACPBridge.toolCallCreateUpdate(for: inspectToolCall)["kind"] as? String == "read")
        #expect(ZenCODEACPBridge.toolCallCreateUpdate(for: directoryCreationToolCall)["kind"] as? String == "edit")
        #expect(ZenCODEACPBridge.toolCallCreateUpdate(for: taskCreationToolCall)["kind"] as? String == "other")
        #expect(ZenCODEACPBridge.toolCallCreateUpdate(for: featureToolCall)["kind"] as? String == "other")
        #expect(ZenCODEACPBridge.acpToolKind("destructive") == "delete")
        #expect(ZenCODEACPBridge.acpToolKind("communicate") == "other")
        #expect(ZenCODEACPBridge.acpToolKind("search") == "search")

        for toolCall in [
            inspectToolCall,
            directoryCreationToolCall,
            taskCreationToolCall,
            featureToolCall
        ] {
            let create = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall)
            let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
                for: toolCall,
                result: DirectAgentToolResult(output: "done", summary: "done")
            )
            for update in [create, completion] {
                let kind = update["kind"] as? String ?? ""
                #expect(acpToolKinds.contains(kind))
            }
        }
    }

    @Test
    func toolCallLocationsResolveRelativePathsAgainstTheSessionWorkspace() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/acp-workspace")
        let relativeToolCall = presentedToolCall(
            id: "call_grep",
            name: "search.grep",
            argumentsObject: [
                "pattern": "needle",
                "path": "Sources/App"
            ],
            argumentsJSON: #"{"pattern":"needle","path":"Sources/App"}"#
        )
        let absoluteToolCall = presentedToolCall(
            id: "call_read",
            name: "local.read",
            argumentsObject: ["path": "/tmp/other/beta.swift"],
            argumentsJSON: #"{"path":"/tmp/other/beta.swift"}"#
        )

        let relativeLocations = ZenCODEACPBridge.toolLocations(
            for: relativeToolCall,
            workingDirectory: workspaceURL
        )
        let absoluteLocations = ZenCODEACPBridge.toolLocations(
            for: absoluteToolCall,
            workingDirectory: workspaceURL
        )

        #expect(relativeLocations.count == 1)
        #expect(relativeLocations.first?["path"] as? String == "/tmp/acp-workspace/Sources/App")
        #expect(absoluteLocations.first?["path"] as? String == "/tmp/other/beta.swift")

        let update = ZenCODEACPBridge.toolCallCreateUpdate(
            for: relativeToolCall,
            workingDirectory: workspaceURL
        )
        let updateLocations = update["locations"] as? [[String: Any]] ?? []
        #expect(updateLocations.first?["path"] as? String == "/tmp/acp-workspace/Sources/App")
    }

    @Test
    func toolCallTitlesAppendOnlySafeFallbackTargetsWithoutPresentation() {
        let searchableToolCall = DirectAgentToolCall(
            id: "call_search",
            name: "custom.search",
            argumentsObject: [
                "query": "needle",
                "content": "sensitive payload"
            ],
            argumentsJSON: "{}"
        )
        let payloadOnlyToolCall = DirectAgentToolCall(
            id: "call_send",
            name: "custom.send",
            argumentsObject: [
                "content": "sensitive payload",
                "token": "secret"
            ],
            argumentsJSON: "{}"
        )

        #expect(ZenCODEACPBridge.toolTitle(for: searchableToolCall) == "custom.search needle")
        #expect(ZenCODEACPBridge.toolTitle(for: payloadOnlyToolCall) == "custom.send")
    }

    // MARK: Standard fields: rawInput, name, rawOutput

    @Test
    func toolCallCreateCarriesNameAndRawInputAsStandardFields() throws {
        let toolCall = presentedToolCall(
            id: "call_read",
            name: "local.read",
            argumentsObject: ["path": "Sources/App.swift", "offset": 10],
            argumentsJSON: #"{"path":"Sources/App.swift","offset":10}"#
        )

        let create = ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall)
        let fields = try #require(create.objectValue)

        #expect(fields["name"] == .string("local.read"))
        #expect(fields["rawInput"] == .object([
            "path": .string("Sources/App.swift"),
            "offset": .number(10),
        ]))
        #expect(fields["_meta"] == nil)
    }

    @Test
    func toolCallCreateCarriesRawInputForToolsWithoutPresentation() throws {
        let toolCall = DirectAgentToolCall(
            id: "call_mcp",
            name: "xcode-tools.XcodeRead",
            argumentsObject: ["filePath": "App/main.swift", "tabIdentifier": "windowtab1"],
            argumentsJSON: #"{"filePath":"App/main.swift","tabIdentifier":"windowtab1"}"#
        )

        let fields = try #require(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall).objectValue)

        #expect(fields["name"] == .string("xcode-tools.XcodeRead"))
        #expect(fields["rawInput"] == .object([
            "filePath": .string("App/main.swift"),
            "tabIdentifier": .string("windowtab1"),
        ]))
        #expect(fields["title"] == .string("xcode-tools.XcodeRead App/main.swift"))
        #expect(fields["kind"] == .string("other"))
    }

    @Test
    func toolCallUpdatesNeverCarryRawInputOrRawOutputInMeta() throws {
        let toolCalls = [
            presentedToolCall(
                id: "call_exec",
                name: "local.exec",
                argumentsObject: ["command": "swift test"],
                argumentsJSON: #"{"command":"swift test"}"#
            ),
            presentedToolCall(
                id: "call_grep",
                name: "search.grep",
                argumentsObject: ["pattern": "needle"],
                argumentsJSON: #"{"pattern":"needle"}"#
            ),
            DirectAgentToolCall(
                id: "call_mcp",
                name: "xcode-tools.BuildProject",
                argumentsObject: ["tabIdentifier": "windowtab1"],
                argumentsJSON: #"{"tabIdentifier":"windowtab1"}"#
            ),
        ]
        let result = DirectAgentToolResult(output: "Build complete.", summary: "Build complete.")

        for toolCall in toolCalls {
            let create = try #require(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall).objectValue)
            let completion = try #require(
                ZenCODEACPBridge.toolCallCompletionJSONUpdate(for: toolCall, result: result).objectValue
            )
            for update in [create, completion] {
                let meta = update["_meta"]?.objectValue ?? [:]
                #expect(meta["rawInput"] == nil)
                #expect(meta["rawOutput"] == nil)
            }
            // The result goes out once, as `content`, and the arguments once,
            // on the `tool_call`.
            #expect(completion["rawOutput"] == nil)
            #expect(completion["rawInput"] == nil)
            #expect(completion["name"] == nil)
            #expect(create["rawOutput"] == nil)
            #expect(completion["content"]?.arrayValue?.count == 1)
        }
    }

    // MARK: Titles

    @Test
    func completionHasNoTitleEvenWhenTheExecutorMeasuredTheDuration() throws {
        let toolCall = presentedToolCall(
            id: "call_timed",
            name: "local.exec",
            argumentsObject: ["command": "git diff --check HEAD"],
            argumentsJSON: #"{"command":"git diff --check HEAD"}"#
        )
        let result = DirectAgentToolResult(
            output: "",
            summary: "No whitespace errors.",
            elapsed: .milliseconds(45)
        )

        let create = try #require(ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall).objectValue)
        let completion = try #require(
            ZenCODEACPBridge.toolCallCompletionJSONUpdate(for: toolCall, result: result).objectValue
        )

        #expect(create["title"] == .string("git diff --check HEAD"))
        #expect(completion["title"] == nil)
        let wire = String(
            decoding: try JSONSerialization.data(withJSONObject: ZenCODEACPBridge.toolCallCompletionUpdate(
                for: toolCall, result: result
            )),
            as: UTF8.self
        )
        #expect(!wire.contains("·"))
    }

    @Test
    func shellCommandTitleIsTheBareCommand() {
        let simple = presentedToolCall(
            id: "call_simple",
            name: "local.exec",
            argumentsObject: ["command": "swift test --filter ACP"],
            argumentsJSON: #"{"command":"swift test --filter ACP"}"#
        )
        let withDirectory = presentedToolCall(
            id: "call_directory",
            name: "local.exec",
            argumentsObject: ["command": "git diff --check HEAD", "workingDirectory": "Sources"],
            argumentsJSON: #"{"command":"git diff --check HEAD","workingDirectory":"Sources"}"#
        )

        #expect(ZenCODEACPBridge.toolTitle(for: simple) == "swift test --filter ACP")
        #expect(ZenCODEACPBridge.toolTitle(for: withDirectory) == "git diff --check HEAD")
        #expect(ZenCODEACPBridge.toolCallCreateUpdate(for: simple)["title"] as? String == "swift test --filter ACP")
        #expect(!ZenCODEACPBridge.toolTitle(for: simple).hasPrefix("local.exec"))
    }

    @Test
    func presentedToolTitleIsActionAndTarget() {
        let read = presentedToolCall(
            id: "call_read",
            name: "local.read",
            argumentsObject: ["path": "Sources/App.swift"],
            argumentsJSON: #"{"path":"Sources/App.swift"}"#
        )
        let search = presentedToolCall(
            id: "call_search",
            name: "search.grep",
            argumentsObject: ["pattern": "needle", "path": "Sources"],
            argumentsJSON: #"{"pattern":"needle","path":"Sources"}"#
        )
        let list = presentedToolCall(
            id: "call_list",
            name: "local.ls",
            argumentsObject: ["path": "Sources/ZenCODECore"],
            argumentsJSON: #"{"path":"Sources/ZenCODECore"}"#
        )
        let pwd = presentedToolCall(
            id: "call_pwd",
            name: "local.pwd",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        #expect(ZenCODEACPBridge.toolTitle(for: read) == "Read Sources/App.swift")
        #expect(ZenCODEACPBridge.toolTitle(for: search) == "Search needle")
        #expect(ZenCODEACPBridge.toolTitle(for: list) == "List Sources/ZenCODECore")
        // No target and no argument: the semantic title of the tool completes
        // the action, instead of a context-free verb.
        #expect(ZenCODEACPBridge.toolTitle(for: pwd) == "Show Working directory")
    }

    @Test
    func presentationWithoutActionFallsBackToTheToolName() {
        let toolCall = presentedToolCall(
            id: "call_custom",
            name: "custom.inspect",
            argumentsObject: ["path": "Sources/App.swift"],
            argumentsJSON: #"{"path":"Sources/App.swift"}"#,
            presentation: ToolPresentationDefinition(
                title: "Inspect",
                action: nil,
                kind: .inspect,
                target: .argument(["path"], format: .path)
            )
        )
        let withoutTarget = presentedToolCall(
            id: "call_custom_bare",
            name: "custom.refresh",
            argumentsObject: [:],
            argumentsJSON: "{}",
            presentation: ToolPresentationDefinition(title: "Refresh", action: "Refresh", kind: .other)
        )

        #expect(ZenCODEACPBridge.toolTitle(for: toolCall) == "custom.inspect Sources/App.swift")
        #expect(ZenCODEACPBridge.toolTitle(for: withoutTarget) == "Refresh")
    }

    @Test
    func toolWithoutPresentationIsTitledWithItsProgrammaticNameAndTarget() {
        let withTarget = DirectAgentToolCall(
            id: "call_mcp_target",
            name: "xcode-tools.XcodeRead",
            argumentsObject: ["filePath": "App/main.swift"],
            argumentsJSON: #"{"filePath":"App/main.swift"}"#
        )
        let withoutTarget = DirectAgentToolCall(
            id: "call_mcp_bare",
            name: "xcode-tools.BuildProject",
            argumentsObject: ["tabIdentifier": "windowtab1"],
            argumentsJSON: #"{"tabIdentifier":"windowtab1"}"#
        )

        #expect(ZenCODEACPBridge.toolTitle(for: withTarget) == "xcode-tools.XcodeRead App/main.swift")
        #expect(ZenCODEACPBridge.toolTitle(for: withoutTarget) == "xcode-tools.BuildProject")
    }

    @Test
    func acpTitleDoesNotChangeTheTitleOtherConsumersUse() {
        let exec = presentedToolCall(
            id: "call_exec",
            name: "local.exec",
            argumentsObject: ["command": "swift test"],
            argumentsJSON: #"{"command":"swift test"}"#
        )
        let read = presentedToolCall(
            id: "call_read",
            name: "local.read",
            argumentsObject: ["path": "Sources/App.swift"],
            argumentsJSON: #"{"path":"Sources/App.swift"}"#
        )

        // Telegram and the Zen app keep the exact tool identity.
        #expect(ToolCallPresentation.toolTitle(for: exec) == "local.exec swift test")
        #expect(ToolCallPresentation.toolTitle(for: read) == "local.read Sources/App.swift")
        #expect(ZenCODEACPBridge.toolTitle(for: exec) != ToolCallPresentation.toolTitle(for: exec))
    }
}
