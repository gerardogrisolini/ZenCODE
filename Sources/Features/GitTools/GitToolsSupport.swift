//
//  GitToolsSupport.swift
//  ZenCODE
//

import Foundation
import FeatureKit

protocol GitWorkingDirectoryInput: WorkingDirectoryInput {
    var workingDirectory: String? { get }
    var cwd: String? { get }
    var path: String? { get }
}

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
        return renderProcessResult(result)
    }

    static func gitWorkingDirectory<T: GitWorkingDirectoryInput>(
        input: T,
        context: FeatureContext
    ) -> URL {
        context.resolvePath(firstNonBlank(input.workingDirectory, input.cwd) ?? ".")
    }

    static func gitStashArguments(action: String, input: GitStashTool.Input) throws -> [String] {
        switch action {
        case "list":
            return ["stash", "list"]
        case "show":
            return ["stash", "show", "--stat", "--patch", input.stash?.nilIfBlank ?? "stash@{0}"]
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
                args.append(stash)
            }
            return args
        default:
            throw GitToolsFeatureError.permissionDenied("Unsupported git stash action: \(action).")
        }
    }

    static func renderProcessResult(_ result: FeatureProcessResult) -> String {
        result.renderedProcessOutput
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

func firstNonBlank(_ values: String?...) -> String? {
    values.compactMap { $0?.nilIfBlank }.first
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
