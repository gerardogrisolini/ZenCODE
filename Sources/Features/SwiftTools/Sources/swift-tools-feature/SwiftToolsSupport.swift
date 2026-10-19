//
//  SwiftToolsSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import ToolCore
import Foundation
import FeatureKit

enum SwiftToolsSupport {
    static func requiredPath(
        _ paths: String?...,
        context: FeatureContext
    ) throws -> URL {
        guard let path = paths.compactMap({ $0?.nilIfBlank }).first else {
            throw SwiftToolsFeatureError.invalidArgument("path is required.")
        }
        return context.resolvePath(path)
    }

    /// Runs `swift <args>` in the resolved working directory with a clamped timeout.
    static func execute(
        _ arguments: [String],
        path: String?,
        workingDirectory: String?,
        timeout: Int?,
        defaultTimeout: Int,
        context: FeatureContext
    ) async throws -> FeatureProcessResult {
        let directory = context.resolvePath([workingDirectory, path].compactMap { $0?.nilIfBlank }.first ?? ".")
        return try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift"] + arguments,
            workingDirectory: directory,
            environment: context.environment,
            timeout: TimeInterval(max(30, min(timeout ?? defaultTimeout, 3600)))
        )
    }

    static func additionalArguments(_ arguments: [String]?) -> [String] {
        (arguments ?? []).filter { !$0.isEmpty }
    }

    static func renderCommand(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard !argument.isEmpty,
                  argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=+".contains($0) }) else {
                return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return argument
        }.joined(separator: " ")
    }
}

enum SwiftToolsFeatureError: LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message):
            return message
        }
    }
}
