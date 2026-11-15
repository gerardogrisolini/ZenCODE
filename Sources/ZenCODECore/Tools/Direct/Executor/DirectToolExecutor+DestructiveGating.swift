//
//  DirectToolExecutor+DestructiveGating.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Authorization gate for destructive direct tools beyond `local.exec`:
//  irreversible filesystem deletion, remote history mutation, and worktree
//  discard, plus `desktop.run` actions that run code or end processes (see
//  DirectToolExecutor+DesktopGating.swift). The gate reuses the session's
//  authorization handler so access modes and per-client permission flows
//  keep applying.
//

import Foundation
import ToolCore

extension DirectToolExecutor {
    /// Tool names that route through the destructive-operation authorization
    /// gate, including `desktop.run` (only for actions that open documents,
    /// launch apps by path, terminate processes, or type text that presses
    /// Return, which is gated as a `local.exec` command). `local.exec` keeps its
    /// own dedicated command-level gate. `local.delete` is listed here so the
    /// gate is consulted, but it only asks for consent when the target escapes
    /// the session's working directory (see
    /// ``deleteTargetIsInsideWorkingDirectory(_:workingDirectory:)``).
    public static let destructiveGatedToolNames: Set<String> = [
        "local.delete",
        "git.push",
        "git.restore",
        "desktop.run"
    ]

    /// Builds the authorization request for a destructive tool call, or nil
    /// when the call is not destructive (e.g. `git.push` dry runs, `git.restore`
    /// that only unstages) or not gated at all.
    static func destructiveAuthorizationRequest(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        delegatedIdentity: AgentToolAuthorizationRequest.DelegatedIdentity? = nil
    ) -> AgentToolAuthorizationRequest? {
        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "local.delete":
            guard let path = arguments.string("path", "file_path")?.nilIfBlank else {
                // Let the tool itself raise the missing-argument error.
                return nil
            }
            // Deleting inside the working directory the session already owns is
            // the ordinary edit surface, so it needs no consent. Only a target
            // that escapes that directory (an absolute path, `..` traversal, or
            // a parent reached through a symlink) is gated.
            guard !deleteTargetIsInsideWorkingDirectory(path, workingDirectory: workingDirectory) else {
                return nil
            }
            let recursive = arguments.bool("recursive") == true
            let command = "delete\(recursive ? " -r" : "") \(shellQuoted(path))"
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Delete \(path)",
                kind: "destructive",
                command: command,
                workingDirectory: workingDirectory.path,
                delegatedIdentity: delegatedIdentity
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
                parts.append(shellQuoted(remote))
            }
            if let refspec = (arguments.string("refspec") ?? arguments.string("branch"))?.nilIfBlank {
                parts.append(shellQuoted(refspec))
            }
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Push to remote",
                kind: "destructive",
                command: parts.joined(separator: " "),
                workingDirectory: workingDirectory.path,
                delegatedIdentity: delegatedIdentity
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
            let target = paths.isEmpty ? "." : paths.map(shellQuoted).joined(separator: " ")
            return AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                title: "Discard worktree changes",
                kind: "destructive",
                command: "git restore --worktree \(target)",
                workingDirectory: workingDirectory.path,
                delegatedIdentity: delegatedIdentity
            )
        case "desktop.run":
            return desktopAuthorizationRequest(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                delegatedIdentity: delegatedIdentity
            )
        default:
            return nil
        }
    }

    /// Whether deleting `path` stays inside the session's working directory.
    ///
    /// The path is resolved the way the file tools resolve it (tilde expansion,
    /// absolute paths kept, relative paths appended to the working directory)
    /// and standardized, so `..` traversal cannot masquerade as a child. The
    /// parent directory is also resolved through symlinks: deleting an entry
    /// only affects that entry, so a symlink inside the working directory is
    /// safe to remove, while a path that reaches outside through a symlinked
    /// parent is not. The working directory itself is not considered inside:
    /// deleting the authorized root is still gated.
    static func deleteTargetIsInsideWorkingDirectory(
        _ path: String,
        workingDirectory: URL
    ) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : workingDirectory.appendingPathComponent(expanded).standardizedFileURL
        let root = workingDirectory.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return isPath(resolvedParent, inside: resolvedRoot)
            && isPath(candidate, inside: root)
    }

    /// Whether `candidate` is `root` or one of its descendants, comparing path
    /// components so siblings with a common textual prefix do not match.
    static func isPath(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Renders one opaque argument for the consent prompt without allowing
    /// whitespace, quotes, or shell metacharacters to blur argument boundaries.
    static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
        )
        if argument.unicodeScalars.allSatisfy(safeCharacters.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                  workingDirectory: workingDirectory,
                  delegatedIdentity: delegatedAuthorizationIdentity
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
