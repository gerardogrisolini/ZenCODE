//
//  LocalPatchSupport.swift
//  ZenCODE
//

import Foundation

extension LocalToolsSupport {
    // MARK: - Unified diff support

    struct DiffHunk {
        let oldStart: Int
        let lines: [DiffLine]
    }

    enum DiffLine {
        case context(String)
        case removed(String)
        case added(String)
    }

    struct FilePatch {
        let path: String
        let isNewFile: Bool
        let isDeletedFile: Bool
        let hunks: [DiffHunk]
    }

    struct FilePatchResult {
        let newContent: String?
        let isDelete: Bool
    }

    private struct PatchTextLines {
        let lines: [String]
        let hadTrailingNewline: Bool

        init(_ text: String, isNewFile: Bool = false) {
            var lines = text.isEmpty && isNewFile
                ? []
                : text.components(separatedBy: "\n")
            let trailingNewline = text.hasSuffix("\n")
            if trailingNewline, lines.last == "" {
                lines.removeLast()
            }
            self.lines = lines
            self.hadTrailingNewline = trailingNewline
        }

        func content(from resultLines: [String], forceTrailingNewline: Bool = false) -> String {
            var content = resultLines.joined(separator: "\n")
            if hadTrailingNewline || forceTrailingNewline {
                content += "\n"
            }
            return content
        }
    }

    enum BeginPatchAction {
        case add
        case update
        case delete
    }

    struct BeginPatchFilePatch {
        let path: String
        let action: BeginPatchAction
        let hunks: [[DiffLine]]
    }

    static func isBeginPatchFormat(_ patch: String) -> Bool {
        patch.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == "*** Begin Patch"
    }

    static func parseBeginPatch(_ patch: String) throws -> [BeginPatchFilePatch] {
        let lines = patch.components(separatedBy: "\n")
        guard lines.contains("*** End Patch") else {
            throw LocalToolsFeatureError.permissionDenied("Malformed patch: missing *** End Patch.")
        }
        var patches: [BeginPatchFilePatch] = []
        var index = 0

        func sectionPath(_ line: String, prefix: String) -> String? {
            guard line.hasPrefix(prefix) else {
                return nil
            }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }

        while index < lines.count {
            let line = lines[index]
            let action: BeginPatchAction
            let path: String
            if let value = sectionPath(line, prefix: "*** Add File: ") {
                action = .add
                path = value
            } else if let value = sectionPath(line, prefix: "*** Update File: ") {
                action = .update
                path = value
            } else if let value = sectionPath(line, prefix: "*** Delete File: ") {
                action = .delete
                path = value
            } else {
                index += 1
                continue
            }

            index += 1
            var hunks: [[DiffLine]] = []
            var currentHunk: [DiffLine] = []

            while index < lines.count {
                let raw = lines[index]
                if raw.hasPrefix("*** Add File: ")
                    || raw.hasPrefix("*** Update File: ")
                    || raw.hasPrefix("*** Delete File: ")
                    || raw == "*** End Patch" {
                    break
                }
                if raw.hasPrefix("@@") {
                    if !currentHunk.isEmpty {
                        hunks.append(currentHunk)
                        currentHunk = []
                    }
                    index += 1
                    continue
                }
                if raw == "\\ No newline at end of file" {
                    index += 1
                    continue
                }

                switch action {
                case .add:
                    if raw.hasPrefix("+") {
                        currentHunk.append(.added(String(raw.dropFirst())))
                    } else if raw.isEmpty {
                        currentHunk.append(.added(""))
                    } else {
                        currentHunk.append(.added(raw))
                    }
                case .update:
                    if raw.hasPrefix("+") {
                        currentHunk.append(.added(String(raw.dropFirst())))
                    } else if raw.hasPrefix("-") {
                        currentHunk.append(.removed(String(raw.dropFirst())))
                    } else if raw.hasPrefix(" ") {
                        currentHunk.append(.context(String(raw.dropFirst())))
                    } else if raw.isEmpty {
                        currentHunk.append(.context(""))
                    } else {
                        currentHunk.append(.context(raw))
                    }
                case .delete:
                    break
                }
                index += 1
            }

            if !currentHunk.isEmpty {
                hunks.append(currentHunk)
            }
            patches.append(BeginPatchFilePatch(path: path, action: action, hunks: hunks))
        }
        return patches
    }

    static func applyBeginPatch(_ filePatch: BeginPatchFilePatch, at url: URL) throws -> FilePatchResult {
        switch filePatch.action {
        case .delete:
            return FilePatchResult(newContent: nil, isDelete: true)
        case .add:
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw LocalToolsFeatureError.permissionDenied("Patch add target already exists: \(filePatch.path).")
            }
            let lines = addedLines(from: filePatch.hunks)
            return FilePatchResult(newContent: lines.joined(separator: "\n") + "\n", isDelete: false)
        case .update:
            let source = PatchTextLines(try String(contentsOf: url, encoding: .utf8))
            let result = try applyBeginPatchHunks(
                filePatch.hunks,
                path: filePatch.path,
                to: source.lines
            )
            return FilePatchResult(newContent: source.content(from: result), isDelete: false)
        }
    }

    private static func addedLines(from hunks: [[DiffLine]]) -> [String] {
        hunks.flatMap { hunk in
            hunk.compactMap { line -> String? in
                if case let .added(text) = line {
                    return text
                }
                return nil
            }
        }
    }

    private static func applyBeginPatchHunks(
        _ hunks: [[DiffLine]],
        path: String,
        to originalLines: [String]
    ) throws -> [String] {
        var result: [String] = []
        var cursor = 0
        for hunk in hunks {
            let pattern = beginPatchPattern(from: hunk)
            guard !pattern.isEmpty else {
                throw LocalToolsFeatureError.permissionDenied("Patch update hunk for \(path) has no context or removals.")
            }
            guard let matchIndex = firstMatch(of: pattern, in: originalLines, startingAt: cursor) else {
                throw LocalToolsFeatureError.permissionDenied("Patch hunk did not match \(path).")
            }
            if matchIndex > cursor {
                result.append(contentsOf: originalLines[cursor..<matchIndex])
            }
            appendBeginPatchHunk(hunk, to: &result)
            cursor = matchIndex + pattern.count
        }
        if cursor < originalLines.count {
            result.append(contentsOf: originalLines[cursor...])
        }
        return result
    }

    private static func beginPatchPattern(from hunk: [DiffLine]) -> [String] {
        hunk.compactMap { line -> String? in
            switch line {
            case let .context(text), let .removed(text):
                return text
            case .added:
                return nil
            }
        }
    }

    private static func appendBeginPatchHunk(_ hunk: [DiffLine], to result: inout [String]) {
        for line in hunk {
            switch line {
            case let .context(text), let .added(text):
                result.append(text)
            case .removed:
                break
            }
        }
    }

    private static func firstMatch(
        of pattern: [String],
        in lines: [String],
        startingAt startIndex: Int
    ) -> Int? {
        guard !pattern.isEmpty, pattern.count <= lines.count else {
            return nil
        }
        var index = max(startIndex, 0)
        while index + pattern.count <= lines.count {
            if lines[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index
            }
            index += 1
        }
        return nil
    }

    static func parseUnifiedDiff(_ patch: String) throws -> [FilePatch] {
        let lines = patch.components(separatedBy: "\n")
        var patches: [FilePatch] = []
        var index = 0

        func stripPrefix(_ path: String) -> String {
            var value = path
            if let tab = value.firstIndex(of: "\t") {
                value = String(value[..<tab])
            }
            if value == "/dev/null" {
                return value
            }
            if value.hasPrefix("a/") || value.hasPrefix("b/") {
                value.removeFirst(2)
            }
            return value
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git") || line.hasPrefix("--- ") {
                var isNewFile = false
                var isDeletedFile = false
                // Skip optional "diff --git" / index / mode lines until "--- ".
                if line.hasPrefix("diff --git") {
                    index += 1
                    while index < lines.count,
                          !lines[index].hasPrefix("--- "),
                          !lines[index].hasPrefix("diff --git") {
                        if lines[index].hasPrefix("new file") {
                            isNewFile = true
                        }
                        if lines[index].hasPrefix("deleted file") {
                            isDeletedFile = true
                        }
                        index += 1
                    }
                }
                guard index < lines.count, lines[index].hasPrefix("--- ") else {
                    continue
                }
                let oldPath = stripPrefix(String(lines[index].dropFirst(4)))
                index += 1
                guard index < lines.count, lines[index].hasPrefix("+++ ") else {
                    throw LocalToolsFeatureError.permissionDenied("Malformed patch: missing +++ header after \(oldPath).")
                }
                let newPath = stripPrefix(String(lines[index].dropFirst(4)))
                index += 1
                if oldPath == "/dev/null" {
                    isNewFile = true
                }
                if newPath == "/dev/null" {
                    isDeletedFile = true
                }
                let targetPath = isDeletedFile ? oldPath : newPath

                var hunks: [DiffHunk] = []
                while index < lines.count, lines[index].hasPrefix("@@") {
                    let header = lines[index]
                    index += 1
                    let oldStart = parseHunkOldStart(header)
                    var hunkLines: [DiffLine] = []
                    while index < lines.count,
                          !lines[index].hasPrefix("@@"),
                          !lines[index].hasPrefix("--- "),
                          !lines[index].hasPrefix("diff --git") {
                        let raw = lines[index]
                        if raw == "\\ No newline at end of file" {
                            index += 1
                            continue
                        }
                        if raw.hasPrefix("+") {
                            hunkLines.append(.added(String(raw.dropFirst())))
                        } else if raw.hasPrefix("-") {
                            hunkLines.append(.removed(String(raw.dropFirst())))
                        } else if raw.hasPrefix(" ") {
                            hunkLines.append(.context(String(raw.dropFirst())))
                        } else if raw.isEmpty {
                            hunkLines.append(.context(""))
                        } else {
                            // Unknown line; stop this hunk.
                            break
                        }
                        index += 1
                    }
                    hunks.append(DiffHunk(oldStart: oldStart, lines: hunkLines))
                }

                patches.append(
                    FilePatch(
                        path: targetPath,
                        isNewFile: isNewFile,
                        isDeletedFile: isDeletedFile,
                        hunks: hunks
                    )
                )
            } else {
                index += 1
            }
        }
        return patches
    }

    private static func parseHunkOldStart(_ header: String) -> Int {
        // Format: @@ -oldStart,oldCount +newStart,newCount @@
        guard let dashRange = header.range(of: "-") else {
            return 1
        }
        let afterDash = header[dashRange.upperBound...]
        let numberPart = afterDash.prefix { $0.isNumber }
        return Int(numberPart) ?? 1
    }

    static func applyFilePatch(_ filePatch: FilePatch, at url: URL) throws -> FilePatchResult {
        if filePatch.isDeletedFile {
            return FilePatchResult(newContent: nil, isDelete: true)
        }

        let source = PatchTextLines(
            try originalText(for: filePatch, at: url),
            isNewFile: filePatch.isNewFile
        )
        let result = try applyUnifiedDiffHunks(
            filePatch.hunks,
            path: filePatch.path,
            to: source.lines
        )
        return FilePatchResult(
            newContent: source.content(from: result, forceTrailingNewline: filePatch.isNewFile),
            isDelete: false
        )
    }

    private static func originalText(for filePatch: FilePatch, at url: URL) throws -> String {
        if filePatch.isNewFile || !FileManager.default.fileExists(atPath: url.path) {
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func applyUnifiedDiffHunks(
        _ hunks: [DiffHunk],
        path: String,
        to originalLines: [String]
    ) throws -> [String] {
        var result: [String] = []
        var cursor = 0

        for hunk in hunks {
            let targetIndex = max(hunk.oldStart - 1, 0)
            if targetIndex > cursor {
                guard targetIndex <= originalLines.count else {
                    throw LocalToolsFeatureError.permissionDenied("Patch hunk for \(path) starts beyond end of file.")
                }
                result.append(contentsOf: originalLines[cursor..<targetIndex])
                cursor = targetIndex
            }
            try appendUnifiedDiffHunk(
                hunk,
                path: path,
                originalLines: originalLines,
                cursor: &cursor,
                result: &result
            )
        }

        if cursor < originalLines.count {
            result.append(contentsOf: originalLines[cursor...])
        }
        return result
    }

    private static func appendUnifiedDiffHunk(
        _ hunk: DiffHunk,
        path: String,
        originalLines: [String],
        cursor: inout Int,
        result: inout [String]
    ) throws {
        for diffLine in hunk.lines {
            switch diffLine {
            case let .context(text):
                try validateOriginalLine(
                    text,
                    path: path,
                    originalLines: originalLines,
                    cursor: cursor,
                    kind: "context"
                )
                result.append(text)
                cursor += 1
            case let .removed(text):
                try validateOriginalLine(
                    text,
                    path: path,
                    originalLines: originalLines,
                    cursor: cursor,
                    kind: "removal"
                )
                cursor += 1
            case let .added(text):
                result.append(text)
            }
        }
    }

    private static func validateOriginalLine(
        _ expectedText: String,
        path: String,
        originalLines: [String],
        cursor: Int,
        kind: String
    ) throws {
        guard cursor < originalLines.count else {
            throw LocalToolsFeatureError.permissionDenied("Patch \(kind) ran past end of \(path).")
        }
        guard originalLines[cursor] == expectedText else {
            throw LocalToolsFeatureError.permissionDenied("Patch \(kind) mismatch in \(path) at line \(cursor + 1): expected \"\(expectedText)\", found \"\(originalLines[cursor])\".")
        }
    }
}
