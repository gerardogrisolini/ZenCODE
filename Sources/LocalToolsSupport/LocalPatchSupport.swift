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
            let lines = filePatch.hunks.flatMap { hunk in
                hunk.compactMap { line -> String? in
                    if case let .added(text) = line {
                        return text
                    }
                    return nil
                }
            }
            return FilePatchResult(newContent: lines.joined(separator: "\n") + "\n", isDelete: false)
        case .update:
            let originalText = try String(contentsOf: url, encoding: .utf8)
            var originalLines = originalText.components(separatedBy: "\n")
            let hadTrailingNewline = originalText.hasSuffix("\n")
            if hadTrailingNewline, originalLines.last == "" {
                originalLines.removeLast()
            }

            var result: [String] = []
            var cursor = 0
            for hunk in filePatch.hunks {
                let pattern = hunk.compactMap { line -> String? in
                    switch line {
                    case let .context(text), let .removed(text):
                        return text
                    case .added:
                        return nil
                    }
                }
                guard !pattern.isEmpty else {
                    throw LocalToolsFeatureError.permissionDenied("Patch update hunk for \(filePatch.path) has no context or removals.")
                }
                guard let matchIndex = firstMatch(of: pattern, in: originalLines, startingAt: cursor) else {
                    throw LocalToolsFeatureError.permissionDenied("Patch hunk did not match \(filePatch.path).")
                }
                if matchIndex > cursor {
                    result.append(contentsOf: originalLines[cursor..<matchIndex])
                }
                for line in hunk {
                    switch line {
                    case let .context(text), let .added(text):
                        result.append(text)
                    case .removed:
                        break
                    }
                }
                cursor = matchIndex + pattern.count
            }
            if cursor < originalLines.count {
                result.append(contentsOf: originalLines[cursor...])
            }

            var newContent = result.joined(separator: "\n")
            if hadTrailingNewline {
                newContent += "\n"
            }
            return FilePatchResult(newContent: newContent, isDelete: false)
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
            if Array(lines[index..<(index + pattern.count)]) == pattern {
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

        let originalText: String
        if filePatch.isNewFile || !FileManager.default.fileExists(atPath: url.path) {
            originalText = ""
        } else {
            originalText = try String(contentsOf: url, encoding: .utf8)
        }
        var originalLines = originalText.isEmpty && filePatch.isNewFile
            ? []
            : originalText.components(separatedBy: "\n")
        let hadTrailingNewline = originalText.hasSuffix("\n")
        if hadTrailingNewline, originalLines.last == "" {
            originalLines.removeLast()
        }

        var result: [String] = []
        var cursor = 0 // index into originalLines

        for hunk in filePatch.hunks {
            let targetIndex = max(hunk.oldStart - 1, 0)
            // Copy untouched lines up to the hunk start.
            if targetIndex > cursor {
                guard targetIndex <= originalLines.count else {
                    throw LocalToolsFeatureError.permissionDenied("Patch hunk for \(filePatch.path) starts beyond end of file.")
                }
                result.append(contentsOf: originalLines[cursor..<targetIndex])
                cursor = targetIndex
            }
            for diffLine in hunk.lines {
                switch diffLine {
                case let .context(text):
                    guard cursor < originalLines.count else {
                        throw LocalToolsFeatureError.permissionDenied("Patch context ran past end of \(filePatch.path).")
                    }
                    guard originalLines[cursor] == text else {
                        throw LocalToolsFeatureError.permissionDenied("Patch context mismatch in \(filePatch.path) at line \(cursor + 1): expected \"\(text)\", found \"\(originalLines[cursor])\".")
                    }
                    result.append(text)
                    cursor += 1
                case let .removed(text):
                    guard cursor < originalLines.count else {
                        throw LocalToolsFeatureError.permissionDenied("Patch removal ran past end of \(filePatch.path).")
                    }
                    guard originalLines[cursor] == text else {
                        throw LocalToolsFeatureError.permissionDenied("Patch removal mismatch in \(filePatch.path) at line \(cursor + 1): expected \"\(text)\", found \"\(originalLines[cursor])\".")
                    }
                    cursor += 1
                case let .added(text):
                    result.append(text)
                }
            }
        }
        // Append any remaining lines after the last hunk.
        if cursor < originalLines.count {
            result.append(contentsOf: originalLines[cursor...])
        }

        var newContent = result.joined(separator: "\n")
        if hadTrailingNewline || filePatch.isNewFile {
            newContent += "\n"
        }
        return FilePatchResult(newContent: newContent, isDelete: false)
    }
}
