//
//  TerminalChat+Utilities.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    nonisolated static func slashCommandArguments(
        from command: String,
        commandPrefix: String
    ) -> String {
        guard command.hasPrefix(commandPrefix) else {
            return ""
        }
        return String(command.dropFirst(commandPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func resolvedWorkspaceFileURL(
        from rawPath: String,
        workingDirectory: URL,
        recognizingFileURLs: Bool = false
    ) -> URL {
        let expandedPath: String
        if rawPath == "~" {
            expandedPath = UserHomeDirectory.current().path
        } else if rawPath.hasPrefix("~/") {
            expandedPath = UserHomeDirectory.current()
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .path
        } else {
            expandedPath = rawPath
        }

        if recognizingFileURLs,
           let fileURL = URL(string: expandedPath),
           fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        return workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}
