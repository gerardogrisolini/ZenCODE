//
//  LocalExecPermissionDialog.swift
//  ZenCODE
//

import Foundation

#if os(macOS)
import AppKit
#endif

extension LocalExecPermissionAuthorizer {
    func presentDialog(
        for request: AgentToolAuthorizationRequest
    ) async -> PermissionDecision? {
        #if os(macOS)
        await Self.presentMacDialog(for: request)
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func presentMacDialog(
        for request: AgentToolAuthorizationRequest
    ) async -> PermissionDecision? {
        let script = """
        on run argv
            set dialogTitle to item 1 of argv
            set workingDirectory to item 2 of argv
            set shellCommand to item 3 of argv
            set dialogText to "A local tool wants to run a command with access to the workspace." & return & return & "Directory:" & return & workingDirectory & return & return & "Command:" & return & shellCommand & return & return & "If you continue, the command may read or modify files, run scripts, and launch other local processes."
            set dialogResult to display dialog dialogText buttons {"Cancel", "Always", "Run"} default button "Run" cancel button "Cancel" with title dialogTitle with icon caution
            return button returned of dialogResult
        end run
        """

        let result: AsyncProcessResult
        do {
            result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [
                    "-e", script,
                    request.title,
                    request.workingDirectory,
                    request.command
                ],
                timeout: nil
            )
        } catch {
            return nil
        }

        guard result.exitCode == 0 else {
            return .deny
        }

        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Run":
            return .allowOnce
        case "Always":
            return .allowAlways
        case "Cancel":
            return .deny
        default:
            return nil
        }
    }
    #endif
}
