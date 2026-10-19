//
//  SwiftToolsSupport+Outline.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import ToolCore
import Foundation
import FeatureKit

extension SwiftToolsSupport {
    struct OutlineEntry {
        let line: Int
        let depth: Int
        let kind: String
        let name: String
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

                if ["struct", "class", "enum", "actor", "protocol", "extension"].contains(entry.kind) {
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

        func entry(_ kind: String, _ name: String) -> OutlineEntry {
            OutlineEntry(line: lineNumber, depth: depth, kind: kind, name: name)
        }

        switch keyword {
        case "class" where tokens.count > 2 && tokens[1] == "func":
            return entry("func", qualified(tokens[2], parent: parentTypeName))
        case "struct", "class", "enum", "actor", "protocol", "extension":
            return tokens.count > 1 ? entry(keyword, tokens[1]) : nil
        case "func":
            return tokens.count > 1 ? entry("func", qualified(tokens[1], parent: parentTypeName)) : nil
        case "init", "subscript":
            return entry(keyword, qualified(keyword, parent: parentTypeName))
        case "var", "let":
            return depth <= 1 && tokens.count > 1 ? entry(keyword, qualified(tokens[1], parent: parentTypeName)) : nil
        case "case":
            return parentTypeName != nil && tokens.count > 1 ? entry("case", tokens[1]) : nil
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
}
