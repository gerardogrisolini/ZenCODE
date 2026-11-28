//
//  ACPWireCompatibilityTests+Permissions.swift
//  ZenCODE
//
//  Wire compatibility tests of the `toolCall` of `session/request_permission`:
//  standard ACP v1 fields only (`rawInput`, `title`, `kind`, `status`), never
//  `_meta.rawInput`, and the bare command as the title of a shell command. A
//  delegated agent's request names the agent in its content, never in its
//  title, and its call is announced by a `tool_call` with the same fields.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension ACPCompatibilityTests {
    private func permissionToolCall(
        for request: AgentToolAuthorizationRequest
    ) throws -> [String: JSONValue] {
        let params = JSONValue.acpValue(from: ACPConsentHost.permissionParams(for: request))
        return try #require(params.objectValue?["toolCall"]?.objectValue)
    }

    @Test
    func shellPermissionToolCallCarriesStandardRawInputAndTheBareCommandTitle() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_exec",
            toolName: "local.exec",
            title: "Run git",
            kind: "execute",
            command: "git diff --check HEAD",
            workingDirectory: "/tmp/project"
        )

        let toolCall = try permissionToolCall(for: request)

        #expect(toolCall["toolCallId"] == .string("call_exec"))
        #expect(toolCall["title"] == .string("git diff --check HEAD"))
        #expect(toolCall["kind"] == .string("execute"))
        #expect(toolCall["status"] == .string("pending"))
        #expect(toolCall["rawInput"] == .object([
            "command": .string("git diff --check HEAD"),
            "workingDirectory": .string("/tmp/project"),
            "description": .string("Run shell command in /tmp/project"),
        ]))
        #expect(toolCall["locations"] == .array([.object(["path": .string("/tmp/project")])]))
        #expect(toolCall["_meta"] == nil)
    }

    @Test
    func nonShellPermissionToolCallKeepsItsReadableTitleAndStandardRawInput() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_delete",
            toolName: "local.delete",
            title: "Delete /tmp/outside/build",
            kind: "destructive",
            command: "delete -r /tmp/outside/build",
            workingDirectory: "/tmp/project"
        )

        let toolCall = try permissionToolCall(for: request)

        #expect(toolCall["title"] == .string("Delete /tmp/outside/build"))
        #expect(toolCall["kind"] == .string("delete"))
        #expect(toolCall["status"] == .string("pending"))
        // The request carries the operation the runtime described for
        // consent, not the original tool arguments.
        #expect(toolCall["rawInput"]?.objectValue?["command"] == .string("delete -r /tmp/outside/build"))
        #expect(toolCall["rawInput"]?.objectValue?["workingDirectory"] == .string("/tmp/project"))
        #expect(toolCall["_meta"] == nil)
    }

    @Test
    func delegatedShellPermissionNamesTheAgentInTheContentNotInTheTitle() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "child-session",
            toolCallID: "call_exec",
            toolName: "local.exec",
            title: "Run swift",
            kind: "execute",
            command: "swift build",
            workingDirectory: "/tmp/project",
            delegatedIdentity: .init(agentID: "agent-1", rootSessionID: "session")
        ).namingDelegatedAgent("Worker")
        // The terminal and Telegram keep the title that names the agent.
        #expect(request.title == "[agent Worker] Run swift")
        #expect(request.delegatedAgentName == "Worker")

        let params = JSONValue.acpValue(from: ACPConsentHost.permissionParams(for: request))
        let toolCall = try permissionToolCall(for: request)

        #expect(params.objectValue?["sessionId"] == .string("session"))
        #expect(toolCall["title"] == .string("swift build"))
        #expect(toolCall["toolCallId"] == .string("acp:tool:agent-1:call_exec"))
        #expect(toolCall["rawInput"]?.objectValue?["command"] == .string("swift build"))
        #expect(toolCall["_meta"] == nil)
        let text = toolCall["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]
        #expect(text == .string("Requested by Worker\n\nDirectory:\n/tmp/project\n\nCommand:\nswift build"))
    }

    @Test
    func delegatedNonShellPermissionDropsTheAgentFromItsTitle() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "child-session",
            toolCallID: "call_delete",
            toolName: "local.delete",
            title: "Delete /tmp/outside/build",
            kind: "destructive",
            command: "delete -r /tmp/outside/build",
            workingDirectory: "/tmp/project",
            delegatedIdentity: .init(agentID: "agent-1", rootSessionID: "session")
        ).namingDelegatedAgent("Worker")

        let toolCall = try permissionToolCall(for: request)

        #expect(toolCall["title"] == .string("Delete /tmp/outside/build"))
        let text = toolCall["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.acpStringValue
        #expect(text?.hasPrefix("Requested by Worker\n\n") == true)
    }

    /// A delegated request the runner did not name falls back to the agent's
    /// id in the content, and its title is the request's own.
    @Test
    func delegatedPermissionWithoutANameNamesTheAgentByItsID() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "child-session",
            toolCallID: "call_delete",
            toolName: "local.delete",
            title: "Delete /tmp/x",
            kind: "destructive",
            command: "delete /tmp/x",
            workingDirectory: "/tmp/project",
            delegatedIdentity: .init(agentID: "agent-1", rootSessionID: "session")
        )

        let toolCall = try permissionToolCall(for: request)

        #expect(toolCall["title"] == .string("Delete /tmp/x"))
        let text = toolCall["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.acpStringValue
        #expect(text?.hasPrefix("Requested by agent-1\n\n") == true)
    }

    /// The `tool_call` that announces a delegated call before its permission:
    /// the permission's id, title, kind, locations and `rawInput`, the tool's
    /// `name`, `pending`, and no content, with no `_meta`.
    @Test
    func delegatedToolCallAnnouncementMatchesItsPermission() throws {
        let request = AgentToolAuthorizationRequest(
            sessionID: "child-session",
            toolCallID: "call_exec",
            toolName: "local.exec",
            title: "Run swift",
            kind: "execute",
            command: "swift build",
            workingDirectory: "/tmp/project",
            delegatedIdentity: .init(agentID: "agent-1", rootSessionID: "session")
        ).namingDelegatedAgent("Worker")

        let announcement = try #require(
            JSONValue.acpValue(from: ACPConsentHost.delegatedToolCallAnnouncement(for: request)).objectValue
        )
        let toolCall = try permissionToolCall(for: request)

        #expect(announcement["sessionUpdate"] == .string("tool_call"))
        #expect(announcement["name"] == .string("local.exec"))
        #expect(announcement["status"] == .string("pending"))
        #expect(announcement["content"] == .array([]))
        #expect(announcement["_meta"] == nil)
        for field in ["toolCallId", "title", "kind", "locations", "rawInput"] {
            #expect(announcement[field] == toolCall[field])
        }
    }

    @Test
    func titleWithoutDelegatedAgentKeepsATitleTheRunnerDidNotName() {
        let plain = AgentToolAuthorizationRequest(
            sessionID: "session", toolCallID: "call", toolName: "local.exec",
            title: "[agent Worker] Run swift", kind: "execute", command: "swift build",
            workingDirectory: "/tmp"
        )
        #expect(plain.titleWithoutDelegatedAgent == "[agent Worker] Run swift")
        let named = plain.withTitle("Run swift").namingDelegatedAgent("Worker")
        #expect(named.titleWithoutDelegatedAgent == "Run swift")
        // Retitling keeps the name: only the title changes.
        #expect(named.withTitle("Run swift").delegatedAgentName == "Worker")
    }
}
