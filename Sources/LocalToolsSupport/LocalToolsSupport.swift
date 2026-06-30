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


public enum LocalFeatureTools {
    public static func fileTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(LocalPwdTool()),
            AnyFeatureTool(LocalListDirectoryTool()),
            AnyFeatureTool(LocalReadFileTool()),
            AnyFeatureTool(LocalReadFilesTool()),
            AnyFeatureTool(LocalWriteFileTool()),
            AnyFeatureTool(LocalReplaceTool()),
            AnyFeatureTool(LocalEditFileTool()),
            AnyFeatureTool(LocalMultiEditTool()),
            AnyFeatureTool(LocalAppendTool()),
            AnyFeatureTool(LocalMakeDirectoryTool()),
            AnyFeatureTool(LocalDeleteTool()),
            AnyFeatureTool(LocalMoveTool()),
            AnyFeatureTool(LocalApplyPatchTool())
        ]
    }

    public static func searchTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(SearchGlobTool()),
            AnyFeatureTool(SearchGrepTool())
        ]
    }

    public static func textTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(TextHeadTool()),
            AnyFeatureTool(TextTailTool()),
            AnyFeatureTool(TextSortTool()),
            AnyFeatureTool(TextWordCountTool())
        ]
    }
}

enum LocalToolsFeatureError: LocalizedError {
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

enum LocalToolsSupport {
    static func requiredPath(
        _ paths: String?...,
        context: FeatureContext
    ) throws -> URL {
        guard let path = paths.compactMap({ $0?.nilIfBlank }).first else {
            throw LocalToolsFeatureError.missingArgument("path")
        }
        return context.resolvePath(path)
    }

    static func requiredString(
        _ values: String?...,
        name: String
    ) throws -> String {
        guard let value = values.compactMap({ $0?.nilIfBlank }).first else {
            throw LocalToolsFeatureError.missingArgument(name)
        }
        return value
    }

    static func requiredRawString(
        _ values: String?...,
        name: String
    ) throws -> String {
        guard let value = values.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw LocalToolsFeatureError.missingArgument(name)
        }
        return value
    }

    static func listDirectory(_ url: URL, includeHidden: Bool) throws -> String {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        guard !entries.isEmpty else {
            return "<empty>"
        }
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return isDirectory ? "\(entry.lastPathComponent)/" : entry.lastPathComponent
            }
            .joined(separator: "\n")
    }

    static func readFile(_ url: URL, offset: Int?, limit: Int?) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let startIndex = max((offset ?? 1) - 1, 0)
        let endIndex = min(
            lines.count,
            startIndex + max(limit ?? min(lines.count, 240), 1)
        )
        guard startIndex < endIndex else {
            return "<empty>"
        }
        return (startIndex..<endIndex)
            .map { index in "\(index + 1)\t\(lines[index])" }
            .joined(separator: "\n")
    }

    static func glob(input: SearchGlobTool.Input, context: FeatureContext) throws -> String {
        var pattern = input.pattern?.nilIfBlank
        let root: URL
        if input.path?.nilIfBlank == nil,
           let rawPattern = pattern,
           let patternPath = existingGlobPatternPath(rawPattern, context: context) {
            root = patternPath
            pattern = nil
        } else {
            root = context.resolvePath(input.path ?? ".")
        }
        let maxResults = max(1, input.maxResults ?? input.max_results ?? 200)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return "<empty>"
        }
        var matches: [String] = []
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            let relative: String
            if url.path.hasPrefix(rootPrefix) {
                relative = String(url.path.dropFirst(rootPrefix.count))
            } else {
                relative = String(url.path.dropFirst(root.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            guard !relative.isEmpty else {
                continue
            }
            let isMatch: Bool
            if let pattern {
                isMatch = fnmatch(pattern, relative, 0) == 0
                    || fnmatch(pattern, url.lastPathComponent, 0) == 0
            } else {
                isMatch = true
            }
            if isMatch {
                matches.append(relative)
                if matches.count >= maxResults {
                    break
                }
            }
        }
        return matches.isEmpty ? "<empty>" : matches.joined(separator: "\n")
    }

    static func existingGlobPatternPath(_ pattern: String, context: FeatureContext) -> URL? {
        guard !pattern.contains("*"),
              !pattern.contains("?"),
              !pattern.contains("[") else {
            return nil
        }

        let url = context.resolvePath(pattern)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static func renderProcessResult(_ result: FeatureProcessResult) -> String {
        var sections = ["exit_code: \(result.exitCode)"]
        if result.timedOut {
            sections.append("timed_out: true")
        }
        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stdout:\n\(result.stdout)")
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stderr:\n\(result.stderr)")
        }
        if sections.count == 1 {
            sections.append("<no output>")
        }
        return sections.joined(separator: "\n")
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
        guard let range = range(of: target) else {
            return self
        }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
