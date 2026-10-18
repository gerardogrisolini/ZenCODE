//
//  GitToolsSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import ToolCore
import Foundation
import FeatureKit

protocol GitWorkingDirectoryInput: WorkingDirectoryInput {}

enum GitToolsSupport {
    static func runGit<T: GitWorkingDirectoryInput>(
        _ arguments: [String],
        input: T,
        context: FeatureContext
    ) async throws -> String {
        let result = try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            workingDirectory: gitWorkingDirectory(input: input, context: context),
            environment: context.environment,
            timeout: 60
        )
        return result.renderedProcessOutput
    }

    static func gitWorkingDirectory<T: GitWorkingDirectoryInput>(
        input: T,
        context: FeatureContext
    ) -> URL {
        context.resolvePath(input.workingDirectory?.nilIfBlank ?? ".")
    }

    /// Validates a model-supplied value that becomes a positional git argument.
    /// Rejects blanks, option-like values (leading `-`) and NUL/newline characters.
    @discardableResult
    static func positional(_ value: String, named name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not be empty.")
        }
        try rejectControlCharacters(trimmed, named: name)
        guard !trimmed.hasPrefix("-") else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not start with '-' (value would be parsed as a git option).")
        }
        return trimmed
    }

    /// Branch/refspec for push, fetch and pull: also rejects the `+` prefix (forced refspec).
    static func refspec(_ value: String, named name: String) throws -> String {
        let trimmed = try positional(value, named: name)
        guard !trimmed.hasPrefix("+") else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not start with '+' (forced refspecs bypass force-with-lease gating).")
        }
        return trimmed
    }

    /// Remote name or URL: also rejects remote helpers that execute commands.
    static func remote(_ value: String) throws -> String {
        let trimmed = try positional(value, named: "remote")
        let lowered = trimmed.lowercased()
        for helper in ["ext::", "fd::"] where lowered.hasPrefix(helper) {
            throw GitToolsFeatureError.permissionDenied("Remote helper '\(helper)' is not allowed.")
        }
        return trimmed
    }

    static func rejectControlCharacters(_ value: String, named name: String) throws {
        if value.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not contain NUL or newline characters.")
        }
    }

    static func gitStashArguments(action: String, input: GitStashTool.Input) throws -> [String] {
        switch action {
        case "list":
            return ["stash", "list"]
        case "show":
            let stash = try positional(input.stash?.nilIfBlank ?? "stash@{0}", named: "stash")
            return ["stash", "show", "--stat", "--patch", stash]
        case "push", "save":
            var args = ["stash", "push"]
            if let message = input.message?.nilIfBlank {
                args.append(contentsOf: ["-m", message])
            }
            if input.includeUntracked == true {
                args.append("--include-untracked")
            }
            if let paths = input.paths, !paths.isEmpty {
                args.append("--")
                args.append(contentsOf: paths)
            }
            return args
        case "apply", "pop", "drop":
            var args = ["stash", action]
            if let stash = input.stash?.nilIfBlank {
                args.append(try positional(stash, named: "stash"))
            }
            return args
        default:
            throw GitToolsFeatureError.permissionDenied("Unsupported git stash action: \(action).")
        }
    }
}

enum GitToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .permissionDenied(message):
            return message
        }
    }
}
