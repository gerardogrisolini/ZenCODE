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

    /// Resolves `workingDirectory ?? path` against the session working
    /// directory and fails clearly when it is missing or not a directory,
    /// instead of letting `Process.run` report an opaque Cocoa error.
    static func packageDirectory(path: String?, workingDirectory: String?, context: FeatureContext) throws -> URL {
        let (name, value): (String, String) = {
            if let workingDirectory = workingDirectory?.nilIfBlank { return ("workingDirectory", workingDirectory) }
            if let path = path?.nilIfBlank { return ("path", path) }
            return ("workingDirectory", ".")
        }()
        let directory = context.resolvePath(value)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw SwiftToolsFeatureError.invalidArgument(
                "Working directory does not exist: \(directory.path) (argument '\(name)')."
            )
        }
        guard isDirectory.boolValue else {
            throw SwiftToolsFeatureError.invalidArgument(
                "Argument '\(name)' must be a package directory, got a file: \(directory.path)."
            )
        }
        return directory
    }

    /// Validates a value that becomes the operand of a SwiftPM option such as
    /// `-c`, `--target`, `--product` or `--filter`. SwiftPM reads the next argv
    /// element verbatim, so an option-like value is not an injection risk, but
    /// rejecting it early turns "Missing value for '--target <target>'" into an
    /// error that names the tool argument.
    static func optionValue(_ value: String, named name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SwiftToolsFeatureError.invalidArgument("Argument '\(name)' must not be empty.")
        }
        guard !trimmed.hasPrefix("-") else {
            throw SwiftToolsFeatureError.invalidArgument(
                "Argument '\(name)' must not start with '-' (value would be parsed as a swift option)."
            )
        }
        guard !trimmed.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw SwiftToolsFeatureError.invalidArgument("Argument '\(name)' must not contain NUL or newline characters.")
        }
        return trimmed
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
        let directory = try packageDirectory(path: path, workingDirectory: workingDirectory, context: context)
        return try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift"] + arguments,
            workingDirectory: directory,
            environment: context.environment,
            timeout: TimeInterval(max(30, min(timeout ?? defaultTimeout, 3600)))
        )
    }

    /// Extra argv elements forwarded verbatim; only empty elements are dropped
    /// because an argument made of whitespace is still a legitimate argument.
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
