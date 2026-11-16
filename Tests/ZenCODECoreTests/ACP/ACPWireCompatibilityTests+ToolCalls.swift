//
//  ACPWireCompatibilityTests+ToolCalls.swift
//  ZenCODE
//
//  Wire compatibility tests of the ACP tool-call updates: the v1 keys, the
//  complete create and completion payloads, tool kinds, locations, and
//  titles.
//

import Foundation
import Synchronization
@testable import ZenCODECore
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
        #expect(create["title"] as? String == "local.exec swift test")
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
        #expect(completion["title"] as? String == "local.exec swift test")
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
            "title": .string("local.exec swift test"),
            "kind": .string("execute"),
            "status": .string("pending"),
            "content": .array([]),
            "locations": .array([.object(["path": .string("/tmp/acp-workspace/Sources")])]),
            "_meta": .object([
                "rawInput": .object([
                    "command": .string("swift test"),
                    "workingDirectory": .string("Sources"),
                ]),
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
                "title": .string("local.exec swift test"),
                "kind": .string("execute"),
                "status": .string(fixture.wireStatus),
                "locations": .array(
                    (fixture.fileChanges.isEmpty
                        ? ["/tmp/acp-workspace/Sources"]
                        : fixture.fileChanges.map(\.path))
                        .map { .object(["path": .string($0)]) }
                ),
                "_meta": .object([
                    "rawInput": .object([
                        "command": .string("swift test"),
                        "workingDirectory": .string("Sources"),
                    ]),
                    "rawOutput": .object([
                        "output": .string(fixture.output),
                        "summary": .string(fixture.summary),
                    ]),
                ]),
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
        let rawOutput = (completion["_meta"] as? [String: Any])?["rawOutput"] as? [String: Any]
        #expect(rawOutput?["output"] as? String == " \n")
    }

    @Test
    func toolCallUpdatesOnlyUseProtocolToolKinds() {
        let acpToolKinds: Set<String> = [
            "read", "edit", "delete", "move", "search",
            "execute", "think", "fetch", "switch_mode", "other"
        ]
        let inspectToolCall = presentedToolCall(
            id: "call_inspect",
            name: "local.inspectFile",
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
            name: "local.readFile",
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
}
