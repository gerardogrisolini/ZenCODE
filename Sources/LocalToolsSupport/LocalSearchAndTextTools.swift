//
//  LocalToolsSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FeatureKit


struct SearchGlobTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pattern: String?
        let path: String?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "search.glob"
    static let description = "Finds files under a local path. Pass pattern for a glob such as **/*.swift; omit pattern to list files recursively."
    static let inputSchema = #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try LocalToolsSupport.glob(input: input, context: context)
    }
}

struct SearchGrepTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pattern: String?
        let path: String?
        let maxResults: Int?
        let max_results: Int?
        let context: Int?
        let filesOnly: Bool?
        let files_only: Bool?
    }

    static let name = "search.grep"
    static let description = "Searches text with grep from a local path. Use context for surrounding lines and filesOnly to list only matching file paths."
    static let inputSchema = #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let pattern = input.pattern?.nilIfBlank else {
            throw LocalToolsFeatureError.missingArgument("pattern")
        }
        let path = context.resolvePath(input.path ?? ".")
        let maxResults = max(1, input.maxResults ?? input.max_results ?? 200)
        let filesOnly = input.filesOnly ?? input.files_only ?? false
        var processArguments = ["-E", "-R", "-n", "-I"]
        if filesOnly {
            processArguments.append("-l")
        } else if let contextLines = input.context, contextLines > 0 {
            processArguments.append(contentsOf: ["-C", "\(min(contextLines, 20))"])
        }
        if maxResults < 10000 {
            processArguments.append(contentsOf: ["-m", "\(maxResults)"])
        }
        processArguments.append(contentsOf: ["-e", pattern, "--"])
        processArguments.append(path.path)
        let result = try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/grep"),
            arguments: processArguments,
            workingDirectory: context.workingDirectory,
            environment: context.environment,
            timeout: 60
        )
        if result.exitCode == 1,
           result.stdout.isEmpty,
           result.stderr.isEmpty {
            return "No matches found."
        }
        return LocalToolsSupport.renderProcessResult(result)
            .components(separatedBy: .newlines)
            .prefix(maxResults)
            .joined(separator: "\n")
    }
}

struct TextHeadTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let lines: Int?
    }

    static let name = "text.head"
    static let description = "Reads the first lines of a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lineCount = max(input.lines ?? 20, 1)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .prefix(lineCount)
        guard !lines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        return (["File: \(path.path)"] + lines.enumerated().map { index, line in
            "\(index + 1)\t\(line)"
        }).joined(separator: "\n")
    }
}

struct TextTailTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let lines: Int?
    }

    static let name = "text.tail"
    static let description = "Reads the last lines of a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lineCount = max(input.lines ?? 20, 1)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        let startIndex = max(lines.count - lineCount, 0)
        let slice = lines[startIndex...]
        return (["File: \(path.path)"] + slice.enumerated().map { index, line in
            "\(startIndex + index + 1)\t\(line)"
        }).joined(separator: "\n")
    }
}

struct TextSortTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let unique: Bool?
    }

    static let name = "text.sort"
    static let description = "Sorts the lines of a local text file and returns the sorted output."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"unique":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
        let sortedLines = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let outputLines: [String]
        if input.unique == true {
            // Already sorted: drop consecutive duplicates instead of building a
            // Set and re-sorting.
            var deduplicated: [String] = []
            for line in sortedLines where deduplicated.last != line {
                deduplicated.append(line)
            }
            outputLines = deduplicated
        } else {
            outputLines = sortedLines
        }
        guard !outputLines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        return (["File: \(path.path)"] + outputLines).joined(separator: "\n")
    }
}

struct TextWordCountTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let filePath: String?
        let file_path: String?
    }

    static let name = "text.wc"
    static let description = "Counts lines, words, and characters in a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let fileURL = try LocalToolsSupport.requiredPath(
            input.path,
            input.file_path,
            input.filePath,
            context: context
        )
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.isEmpty ? 0 : contents.components(separatedBy: .newlines).count
        let words = contents.split { $0.isWhitespace || $0.isNewline }.count
        let characters = contents.count
        return """
        File: \(fileURL.path)
        lines: \(lines)
        words: \(words)
        characters: \(characters)
        """
    }
}
