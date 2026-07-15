//
//  DirectToolDestructiveGatingTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct DirectToolDestructiveGatingTests {
    @Test
    func destructiveRequestIsBuiltForDeletePushAndDiscardingRestore() {
        let cwd = URL(fileURLWithPath: "/tmp/workspace")

        let deleteRequest = DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "local.delete", arguments: ["path": "notes.txt", "recursive": true]),
            workingDirectory: cwd
        )
        #expect(deleteRequest?.toolName == "local.delete")
        #expect(deleteRequest?.command == "delete -r notes.txt")

        let pushRequest = DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "git.push", arguments: ["remote": "origin", "branch": "main", "forceWithLease": true]),
            workingDirectory: cwd
        )
        #expect(pushRequest?.command == "git push --force-with-lease origin main")

        let restoreRequest = DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "git.restore", arguments: ["worktree": true, "discardChanges": true, "paths": ["a.swift"]]),
            workingDirectory: cwd
        )
        #expect(restoreRequest?.command == "git restore --worktree a.swift")
    }

    @Test
    func nonDestructiveVariantsAreNotGated() {
        let cwd = URL(fileURLWithPath: "/tmp/workspace")

        #expect(DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "git.push", arguments: ["dryRun": true]),
            workingDirectory: cwd
        ) == nil)

        #expect(DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "git.restore", arguments: ["staged": true, "paths": ["a.swift"]]),
            workingDirectory: cwd
        ) == nil)

        #expect(DirectToolExecutor.destructiveAuthorizationRequest(
            sessionID: "s",
            toolCall: toolCall(name: "local.readFile", arguments: ["path": "a.swift"]),
            workingDirectory: cwd
        ) == nil)
    }

    @Test
    func deniedDeleteLeavesFileInPlaceAndReportsCancellation() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("keep.txt")
        try "keep me".write(to: fileURL, atomically: true, encoding: .utf8)

        let executor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let result = await executor.execute(
            sessionID: "gating-tests",
            toolCall: toolCall(name: "local.delete", arguments: ["path": fileURL.path]),
            workingDirectory: workspace,
            allowedToolNames: nil
        )

        #expect(result.output.contains("Operation cancelled."))
        #expect(result.output.contains("local.delete"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func approvedDeleteProceedsAndCapturesRequest() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("gone.txt")
        try "delete me".write(to: fileURL, atomically: true, encoding: .utf8)

        let capturedRequests = CapturedAuthorizationRequests()
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await capturedRequests.append(request)
                return true
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let result = await executor.execute(
            sessionID: "gating-tests",
            toolCall: toolCall(name: "local.delete", arguments: ["path": fileURL.path]),
            workingDirectory: workspace,
            allowedToolNames: nil
        )

        #expect(!result.output.contains("Operation cancelled."))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let requests = await capturedRequests.requests
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "local.delete")
        #expect(requests.first?.kind == "destructive")
    }

    @Test
    func gatedToolNamesIncludeShellAndDestructiveTools() {
        #expect(LocalExecPermissionAuthorizer.gatedToolNames.contains("local.exec"))
        #expect(LocalExecPermissionAuthorizer.gatedToolNames.contains("local.delete"))
        #expect(LocalExecPermissionAuthorizer.gatedToolNames.contains("git.push"))
        #expect(LocalExecPermissionAuthorizer.gatedToolNames.contains("git.restore"))
        #expect(!LocalExecPermissionAuthorizer.gatedToolNames.contains("local.readFile"))
    }

    private func toolCall(name: String, arguments: [String: Any]) -> DirectAgentToolCall {
        let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return DirectAgentToolCall(
            id: UUID().uuidString,
            name: name,
            argumentsObject: arguments,
            argumentsJSON: argumentsJSON
        )
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor CapturedAuthorizationRequests {
    private(set) var requests: [AgentToolAuthorizationRequest] = []

    func append(_ request: AgentToolAuthorizationRequest) {
        requests.append(request)
    }
}
