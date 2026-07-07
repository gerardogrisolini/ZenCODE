//
//  SwiftToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import Foundation
import FeatureKit

struct SwiftBuildTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let target: String?
        let product: String?
        let configuration: String?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.build"
    static let description = "Builds a SwiftPM package with `swift build` and returns a structured summary of errors and warnings instead of raw output."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"target":{"type":"string"},"product":{"type":"string"},"configuration":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["build"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", configuration])
        }
        if let target = input.target?.nilIfBlank {
            args.append(contentsOf: ["--target", target])
        }
        if let product = input.product?.nilIfBlank {
            args.append(contentsOf: ["--product", product])
        }
        let timeout = TimeInterval(max(30, min(input.timeoutSeconds ?? input.timeout ?? 900, 3600)))
        let workingDirectory = SwiftToolsSupport.workingDirectory(
            path: input.path,
            workingDirectory: input.workingDirectory,
            cwd: input.cwd,
            context: context
        )
        let result = try await SwiftToolsSupport.runSwift(
            args,
            workingDirectory: workingDirectory,
            environment: context.environment,
            timeout: timeout
        )
        return SwiftToolsSupport.renderBuildResult(result, command: "swift " + args.joined(separator: " "))
    }
}

struct SwiftTestTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let filter: String?
        let target: String?
        let configuration: String?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.test"
    static let description = "Runs SwiftPM tests with `swift test` and returns a structured summary of failing tests and build errors instead of raw output. Prefer this over local.exec for SwiftPM tests; pass filter for targeted tests and timeoutSeconds for long suites."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"filter":{"type":"string"},"target":{"type":"string"},"configuration":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["test"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", configuration])
        }
        if let filter = input.filter?.nilIfBlank {
            args.append(contentsOf: ["--filter", filter])
        } else if let target = input.target?.nilIfBlank {
            args.append(contentsOf: ["--filter", target])
        }
        let timeout = TimeInterval(max(30, min(input.timeoutSeconds ?? input.timeout ?? 1200, 3600)))
        let workingDirectory = SwiftToolsSupport.workingDirectory(
            path: input.path,
            workingDirectory: input.workingDirectory,
            cwd: input.cwd,
            context: context
        )
        let result = try await SwiftToolsSupport.runSwift(
            args,
            workingDirectory: workingDirectory,
            environment: context.environment,
            timeout: timeout
        )
        return SwiftToolsSupport.renderTestResult(result, command: "swift " + args.joined(separator: " "))
    }
}

struct SwiftRunTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let executable: String?
        let product: String?
        let configuration: String?
        let arguments: [String]?
        let args: [String]?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.run"
    static let description = "Builds if needed and runs an executable product of a SwiftPM package with `swift run`. Pass executable and optional arguments. Returns build diagnostics plus the program output."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"executable":{"type":"string"},"product":{"type":"string"},"configuration":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"args":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["run"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", configuration])
        }
        if let executable = (input.executable ?? input.product)?.nilIfBlank {
            args.append(executable)
        }
        let passthrough = (input.arguments ?? input.args ?? [])
            .compactMap { $0.nilIfBlank }
        if !passthrough.isEmpty {
            args.append(contentsOf: passthrough)
        }
        let timeout = TimeInterval(max(30, min(input.timeoutSeconds ?? input.timeout ?? 900, 3600)))
        let workingDirectory = SwiftToolsSupport.workingDirectory(
            path: input.path,
            workingDirectory: input.workingDirectory,
            cwd: input.cwd,
            context: context
        )
        let result = try await SwiftToolsSupport.runSwift(
            args,
            workingDirectory: workingDirectory,
            environment: context.environment,
            timeout: timeout
        )
        return SwiftToolsSupport.renderRunResult(result, command: "swift " + args.joined(separator: " "))
    }
}

struct SwiftPackageTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let action: String?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.package"
    static let description = "Runs `swift package` subcommands. action is one of: resolve, update, clean, reset, describe, dump-package. describe and dump-package report targets, products, and dependencies without reading Package.swift by hand."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"action":{"type":"string","enum":["resolve","update","clean","reset","describe","dump-package"]},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let action = (input.action?.nilIfBlank ?? "describe").lowercased()
        let allowed: Set<String> = ["resolve", "update", "clean", "reset", "describe", "dump-package"]
        guard allowed.contains(action) else {
            throw SwiftToolsFeatureError.invalidArgument(
                "action must be one of: resolve, update, clean, reset, describe, dump-package."
            )
        }
        var args = ["package", action]
        if action == "describe" {
            args.append(contentsOf: ["--type", "json"])
        }
        let defaultTimeout = (action == "update" || action == "resolve") ? 600 : 120
        let timeout = TimeInterval(max(30, min(input.timeoutSeconds ?? input.timeout ?? defaultTimeout, 3600)))
        let workingDirectory = SwiftToolsSupport.workingDirectory(
            path: input.path,
            workingDirectory: input.workingDirectory,
            cwd: input.cwd,
            context: context
        )
        let result = try await SwiftToolsSupport.runSwift(
            args,
            workingDirectory: workingDirectory,
            environment: context.environment,
            timeout: timeout
        )
        return SwiftToolsSupport.renderPackageResult(result, command: "swift " + args.joined(separator: " "))
    }
}

struct SwiftOutlineTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let maxSymbols: Int?
        let max_symbols: Int?
    }

    static let name = "swift.outline"
    static let description = "Returns a compact outline of Swift declarations in a source file without returning the full file contents."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"maxSymbols":{"type":"number"},"max_symbols":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try SwiftToolsSupport.requiredPath(input.path, input.file_path, context: context)
        return try SwiftToolsSupport.renderSwiftOutline(
            fileURL: path,
            maxSymbols: input.maxSymbols ?? input.max_symbols
        )
    }
}

@main
struct SwiftToolsFeatureMain {
    static func main() async {
        await FeatureRunner.run([
            AnyFeatureTool(SwiftBuildTool()),
            AnyFeatureTool(SwiftTestTool()),
            AnyFeatureTool(SwiftRunTool()),
            AnyFeatureTool(SwiftPackageTool()),
            AnyFeatureTool(SwiftOutlineTool())
        ])
    }
}

private enum SwiftToolsSupport {
    struct OutlineEntry {
        let line: Int
        let depth: Int
        let kind: String
        let name: String
    }

    static func requiredPath(
        _ paths: String?...,
        context: FeatureContext
    ) throws -> URL {
        guard let path = paths.compactMap({ $0?.nilIfBlank }).first else {
            throw SwiftToolsFeatureError.invalidArgument("path is required.")
        }
        return context.resolvePath(path)
    }

    static func workingDirectory(
        path: String?,
        workingDirectory: String?,
        cwd: String?,
        context: FeatureContext
    ) -> URL {
        let candidate = [workingDirectory, cwd, path]
            .compactMap { $0?.nilIfBlank }
            .first
        return context.resolvePath(candidate ?? ".")
    }

    static func runSwift(
        _ arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> FeatureProcessResult {
        try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift"] + arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
    }

    static func renderSwiftOutline(fileURL: URL, maxSymbols: Int?) throws -> String {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SwiftToolsFeatureError.invalidArgument("File is not valid UTF-8: \(fileURL.path)")
        }

        let lines = text.isEmpty ? [] : text.components(separatedBy: .newlines)
        let maxEntries = max(maxSymbols ?? 120, 1)
        let outline = swiftOutlineEntries(in: lines, maxEntries: maxEntries)
        var output = [
            "File: \(fileURL.path)",
            "lines: \(lines.count)",
            "symbols: \(outline.entries.count)",
            "read_hint: local.readFile path=\"\(fileURL.path)\" offset=<line> limit=80",
            "outline:"
        ]

        if outline.entries.isEmpty {
            output.append("<no Swift declarations found>")
        } else {
            output.append(contentsOf: outline.entries.map { entry in
                "\(entry.line)\t\(entry.depth)\t\(entry.kind)\t\(entry.name)"
            })
            if outline.truncated {
                output.append("... outline truncated to \(maxEntries) entries ...")
            }
        }
        return output.joined(separator: "\n")
    }

    static func swiftOutlineEntries(
        in lines: [String],
        maxEntries: Int
    ) -> (entries: [OutlineEntry], truncated: Bool) {
        var entries: [OutlineEntry] = []
        var braceDepth = 0
        var typeStack: [(name: String, depth: Int)] = []
        var inBlockComment = false

        for (index, rawLine) in lines.enumerated() {
            let sanitized = codePortion(
                of: rawLine,
                inBlockComment: &inBlockComment
            )
            let currentDepth = max(braceDepth, 0)
            while let last = typeStack.last, currentDepth <= last.depth {
                typeStack.removeLast()
            }

            if let entry = swiftOutlineEntry(
                for: sanitized,
                lineNumber: index + 1,
                depth: currentDepth,
                parentTypeName: typeStack.last?.name
            ) {
                guard entries.count < maxEntries else {
                    return (entries, true)
                }
                entries.append(entry)

                if entry.kind == "struct"
                    || entry.kind == "class"
                    || entry.kind == "enum"
                    || entry.kind == "actor"
                    || entry.kind == "protocol"
                    || entry.kind == "extension" {
                    typeStack.append((entry.name, currentDepth))
                }
            }

            braceDepth += braceDelta(in: sanitized)
            braceDepth = max(braceDepth, 0)
        }

        return (entries, false)
    }

    private static func swiftOutlineEntry(
        for line: String,
        lineNumber: Int,
        depth: Int,
        parentTypeName: String?
    ) -> OutlineEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("// MARK:") {
            let name = trimmed.replacingOccurrences(of: "// MARK:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : OutlineEntry(line: lineNumber, depth: depth, kind: "mark", name: name)
        }

        guard !trimmed.hasPrefix("//") else {
            return nil
        }

        var tokens = swiftTokens(from: trimmed)
        let modifiers: Set<String> = [
            "public", "private", "fileprivate", "internal", "open",
            "static", "final", "override", "mutating", "nonmutating",
            "nonisolated", "isolated", "async", "throws", "rethrows",
            "convenience", "required", "optional", "indirect", "lazy",
            "weak", "unowned"
        ]
        while let first = tokens.first,
              first.hasPrefix("@") || modifiers.contains(first) {
            tokens.removeFirst()
        }

        guard let keyword = tokens.first else {
            return nil
        }

        switch keyword {
        case "class" where tokens.count > 2 && tokens[1] == "func":
            return OutlineEntry(
                line: lineNumber,
                depth: depth,
                kind: "func",
                name: qualified(tokens[2], parent: parentTypeName)
            )
        case "struct", "class", "enum", "actor", "protocol", "extension":
            guard tokens.count > 1 else {
                return nil
            }
            return OutlineEntry(line: lineNumber, depth: depth, kind: keyword, name: tokens[1])
        case "func":
            guard tokens.count > 1 else {
                return nil
            }
            return OutlineEntry(
                line: lineNumber,
                depth: depth,
                kind: "func",
                name: qualified(tokens[1], parent: parentTypeName)
            )
        case "init":
            return OutlineEntry(
                line: lineNumber,
                depth: depth,
                kind: "init",
                name: qualified("init", parent: parentTypeName)
            )
        case "subscript":
            return OutlineEntry(
                line: lineNumber,
                depth: depth,
                kind: "subscript",
                name: qualified("subscript", parent: parentTypeName)
            )
        case "var", "let":
            guard depth <= 1,
                  tokens.count > 1 else {
                return nil
            }
            return OutlineEntry(
                line: lineNumber,
                depth: depth,
                kind: keyword,
                name: qualified(tokens[1], parent: parentTypeName)
            )
        case "case":
            guard parentTypeName != nil,
                  tokens.count > 1 else {
                return nil
            }
            return OutlineEntry(line: lineNumber, depth: depth, kind: "case", name: tokens[1])
        default:
            return nil
        }
    }

    private static func qualified(_ name: String, parent: String?) -> String {
        guard let parent, !name.contains(".") else {
            return name
        }
        return "\(parent).\(name)"
    }

    private static func swiftTokens(from line: String) -> [String] {
        line.split { character in
            character.isWhitespace
                || "({[,:<>=})]".contains(character)
        }.map(String.init)
    }

    private static func codePortion(
        of line: String,
        inBlockComment: inout Bool
    ) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if inBlockComment {
                if line[index...].hasPrefix("*/") {
                    inBlockComment = false
                    index = line.index(index, offsetBy: 2)
                } else {
                    index = line.index(after: index)
                }
                continue
            }

            if line[index...].hasPrefix("/*") {
                inBlockComment = true
                index = line.index(index, offsetBy: 2)
                continue
            }
            if line[index...].hasPrefix("//") {
                if result.trimmingCharacters(in: .whitespaces).isEmpty {
                    return String(line[index...])
                }
                break
            }
            result.append(line[index])
            index = line.index(after: index)
        }
        return result
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var inString = false
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = inString
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else {
                continue
            }
            if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }
        return delta
    }

    // MARK: - Rendering

    static func renderBuildResult(_ result: FeatureProcessResult, command: String) -> String {
        let combined = result.stdout + "\n" + result.stderr
        let diagnostics = parseDiagnostics(from: combined)
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        var lines: [String] = []
        lines.append("command: \(command)")
        if result.timedOut {
            lines.append("status: timed_out")
        } else {
            lines.append("status: \(result.exitCode == 0 ? "success" : "failed") (exit \(result.exitCode))")
        }
        lines.append("errors: \(errors.count)  warnings: \(warnings.count)")

        if !errors.isEmpty {
            lines.append("\nErrors:")
            lines.append(contentsOf: errors.prefix(50).map { "  " + $0.formatted })
        }
        if !warnings.isEmpty {
            lines.append("\nWarnings:")
            lines.append(contentsOf: warnings.prefix(30).map { "  " + $0.formatted })
        }
        if result.exitCode != 0 {
            // Always surface raw output tail when build fails, even when parsed diagnostics exist,
            // so the model can see full context that structured parsing may have missed.
            lines.append("\nRaw output:")
            lines.append(tail(of: combined, lines: 60))
        }
        return lines.joined(separator: "\n")
    }

    static func renderTestResult(_ result: FeatureProcessResult, command: String) -> String {
        let combined = result.stdout + "\n" + result.stderr
        let diagnostics = parseDiagnostics(from: combined)
        let buildErrors = diagnostics.filter { $0.severity == .error }
        let failures = parseTestFailures(from: combined)
        let summary = parseTestSummary(from: combined)

        var lines: [String] = []
        lines.append("command: \(command)")
        if result.timedOut {
            lines.append("status: timed_out")
        } else {
            lines.append("status: \(result.exitCode == 0 ? "passed" : "failed") (exit \(result.exitCode))")
        }
        if let summary {
            lines.append("summary: \(summary)")
        }

        if !buildErrors.isEmpty {
            lines.append("\nBuild errors: \(buildErrors.count)")
            lines.append(contentsOf: buildErrors.prefix(50).map { "  " + $0.formatted })
        }
        if !failures.isEmpty {
            lines.append("\nFailing tests: \(failures.count)")
            lines.append(contentsOf: failures.prefix(50).map { "  " + $0 })
        }
        if result.exitCode != 0 {
            // Always surface raw output tail when tests fail, so the model sees full context.
            lines.append("\nRaw output:")
            lines.append(tail(of: combined, lines: 60))
        }
        return lines.joined(separator: "\n")
    }

    static func renderRunResult(_ result: FeatureProcessResult, command: String) -> String {
        let stderr = result.stderr
        // swift run prints build diagnostics to stderr; program output goes to stdout.
        let errors = parseDiagnostics(from: stderr).filter { $0.severity == .error }

        var lines: [String] = []
        lines.append("command: \(command)")
        if result.timedOut {
            lines.append("status: timed_out")
        } else {
            lines.append("status: \(result.exitCode == 0 ? "success" : "failed") (exit \(result.exitCode))")
        }
        if !errors.isEmpty {
            lines.append("\nBuild errors: \(errors.count)")
            lines.append(contentsOf: errors.prefix(50).map { "  " + $0.formatted })
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            lines.append("\nstdout:")
            lines.append(stdout)
        }
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 {
            // Always surface raw stderr tail when run fails, so the model sees full context.
            if !trimmedStderr.isEmpty {
                lines.append("\nstderr:")
                lines.append(tail(of: trimmedStderr, lines: 60))
            }
        }
        if stdout.isEmpty, errors.isEmpty, result.exitCode == 0 {
            lines.append("<no output>")
        }
        return lines.joined(separator: "\n")
    }

    static func renderPackageResult(_ result: FeatureProcessResult, command: String) -> String {
        var lines: [String] = []
        lines.append("command: \(command)")
        if result.timedOut {
            lines.append("status: timed_out")
        } else {
            lines.append("status: \(result.exitCode == 0 ? "success" : "failed") (exit \(result.exitCode))")
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            lines.append("")
            lines.append(stdout)
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty, result.exitCode != 0 || stdout.isEmpty {
            lines.append("\nstderr:")
            lines.append(tail(of: stderr, lines: 40))
        }
        if stdout.isEmpty, stderr.isEmpty {
            lines.append("<no output>")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    enum Severity {
        case error
        case warning
    }

    struct Diagnostic {
        let severity: Severity
        let location: String
        let message: String

        var formatted: String {
            location.isEmpty ? message : "\(location): \(message)"
        }
    }

    /// Parses `file:line:col: error|warning: message` diagnostics, deduplicated.
    static func parseDiagnostics(from output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let severity = severity(in: trimmed) else {
                continue
            }
            let marker = severity == .error ? "error:" : "warning:"
            guard let markerRange = trimmed.range(of: marker) else {
                continue
            }
            let location = String(trimmed[..<markerRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            let message = String(trimmed[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let key = "\(location)|\(message)"
            guard seen.insert(key).inserted else {
                continue
            }
            diagnostics.append(
                Diagnostic(severity: severity, location: location, message: message)
            )
        }
        return diagnostics
    }

    private static func severity(in line: String) -> Severity? {
        // Require a "file:line:..." style prefix to avoid matching prose.
        if line.contains(": error:") || line.hasPrefix("error: ") {
            return .error
        }
        if line.contains(": warning:") || line.hasPrefix("warning: ") {
            return .warning
        }
        return nil
    }

    /// Captures both XCTest and swift-testing failure lines.
    static func parseTestFailures(from output: String) -> [String] {
        var failures: [String] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFailure = (trimmed.contains("error:") && trimmed.contains(" failed"))
                || trimmed.hasPrefix("✘")
                || trimmed.contains("recorded an issue")
                || (trimmed.contains("Test Case") && trimmed.contains("failed"))
            guard isFailure else {
                continue
            }
            guard seen.insert(trimmed).inserted else {
                continue
            }
            failures.append(trimmed)
        }
        return failures
    }

    static func parseTestSummary(from output: String) -> String? {
        var summary: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Test run with")
                || trimmed.hasPrefix("Executed ")
                || (trimmed.hasPrefix("Test Suite") && (trimmed.contains("passed") || trimmed.contains("failed"))) {
                summary = trimmed
            }
        }
        return summary
    }

    private static func tail(of text: String, lines count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(count).joined(separator: "\n")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum SwiftToolsFeatureError: LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message):
            return message
        }
    }
}
