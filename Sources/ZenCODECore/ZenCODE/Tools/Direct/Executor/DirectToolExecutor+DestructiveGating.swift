//
//  DirectToolExecutor+DestructiveGating.swift
//  ZenCODE
//
//  Authorization gate for destructive direct tools beyond `local.exec`:
//  irreversible filesystem deletion, remote history mutation, and worktree
//  discard. The gate reuses the session's authorization handler so access
//  modes and per-client permission flows keep applying.
//

import Foundation

extension DirectToolExecutor {
    /// Tool names that route through the destructive-operation authorization
    /// gate. `local.exec` keeps its own dedicated command-level gate.
    public static let destructiveGatedToolNames: Set<String> = [
        "local.delete",
        "git.push",
        "git.restore"
    ]

    /// Builds the authorization request for a destructive tool call, or nil
    /// when the call is not destructive (e.g. `git.push` dry runs, `git.restore`
    /// that only unstages) or not gated at all.
    static func destructiveAuthorizationRequest(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) -> AgentToolAuthorizationRequest? {
        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "local.delete":
            guard let path = arguments.string("path", "file_path")?.nilIfBlank else {
                // Let the tool itself raise the missing-argument error.
                return nil
            }
            let recursive = arguments.bool("recursive") == true
            let command = "delete\(recursive ? " -r" : "") \(path)"
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Delete \(path)",
                kind: "destructive",
                command: command,
                workingDirectory: workingDirectory.path
            )
        case "git.push":
            guard arguments.bool("dryRun", "dry_run") != true else {
                return nil
            }
            var parts = ["git", "push"]
            if arguments.bool("forceWithLease", "force_with_lease") == true {
                parts.append("--force-with-lease")
            }
            if let remote = arguments.string("remote")?.nilIfBlank {
                parts.append(remote)
            }
            if let refspec = (arguments.string("refspec") ?? arguments.string("branch"))?.nilIfBlank {
                parts.append(refspec)
            }
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Push to remote",
                kind: "destructive",
                command: parts.joined(separator: " "),
                workingDirectory: workingDirectory.path
            )
        case "git.restore":
            // Unstaging is safe; only discarding worktree changes is gated.
            guard arguments.bool("discardChanges") == true,
                  arguments.bool("worktree") == true else {
                return nil
            }
            let paths = arguments.stringArray("paths")
                ?? arguments.string("path").map { [$0] }
                ?? []
            let target = paths.isEmpty ? "." : paths.joined(separator: " ")
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Discard worktree changes",
                kind: "destructive",
                command: "git restore --worktree \(target)",
                workingDirectory: workingDirectory.path
            )
        default:
            return nil
        }
    }

    /// Returns a denial message when the destructive tool call is not approved,
    /// or nil when the call may proceed (not destructive, no handler, or
    /// approved by the user).
    func deniedDestructiveToolOutputIfNeeded(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async -> String? {
        guard let authorizationHandler,
              let request = Self.destructiveAuthorizationRequest(
                  sessionID: sessionID,
                  toolCall: toolCall,
                  workingDirectory: workingDirectory
              ) else {
            return nil
        }
        guard await authorizationHandler(request) else {
            return """
            Operation cancelled.
            The user did not approve this `\(toolCall.name)` request, so no changes were made.

            Requested operation:
            \(request.command)
            """
        }
        return nil
    }
}
