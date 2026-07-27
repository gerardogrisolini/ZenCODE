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


struct TextLinesInput: Decodable, Sendable {
    let path: String?
    let file_path: String?
    let lines: Int?
}

let textLinesInputSchema = buildInputSchema(
    [.string("path"), .number("lines")],
    required: ["path"]
)

enum TextLineSelection: Equatable, Sendable { case head, tail }

func runTextLines(
    _ input: TextLinesInput, context: FeatureContext, selection: TextLineSelection
) async throws -> String {
    let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
    let lineCount = max(input.lines ?? 20, 1)
    return try await LocalIOOffloader.run {
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
        let selectedLines = selection == .head ? lines.prefix(lineCount) : lines.suffix(lineCount)
        guard !selectedLines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        return (["File: \(path.path)"] + selectedLines.enumerated().map { index, line in
            "\(selectedLines.startIndex + index + 1)\t\(line)"
        }).joined(separator: "\n")
    }
}

struct TextHeadTool: FeatureTool {
    typealias Input = TextLinesInput

    static let name = "text.head"
    static let description = "Reads the first lines of a local text file."
    static let inputSchema = textLinesInputSchema

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try await runTextLines(input, context: context, selection: .head)
    }
}

struct TextTailTool: FeatureTool {
    typealias Input = TextLinesInput

    static let name = "text.tail"
    static let description = "Reads the last lines of a local text file."
    static let inputSchema = textLinesInputSchema

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try await runTextLines(input, context: context, selection: .tail)
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
    static let inputSchema = buildInputSchema(
        [.string("path"), .boolean("unique")],
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let unique = input.unique == true
        return try await LocalIOOffloader.run {
            let lines = try String(contentsOf: path, encoding: .utf8)
                .components(separatedBy: .newlines)
            let sortedLines = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let outputLines: [String]
            if unique {
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
}

struct TextWordCountTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let filePath: String?
        let file_path: String?
    }

    static let name = "text.wc"
    static let description = "Counts lines, words, and characters in a local text file."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases,
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let fileURL = try LocalToolsSupport.requiredPath(
            input.path,
            input.file_path,
            input.filePath,
            context: context
        )
        return try await LocalIOOffloader.run {
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
}
