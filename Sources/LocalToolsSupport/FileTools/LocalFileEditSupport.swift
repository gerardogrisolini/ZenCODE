import Foundation

enum LocalFileLineEndingStyle: String, Sendable {
    case none
    case lf
    case crlf
    case cr
    case mixed

    var separator: String? {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        case .none, .mixed: nil
        }
    }
}

struct LocalFileEditResult: Sendable {
    let contents: String
    let replacedRange: Range<String.Index>
    let originalLine: Int
    let originalLineCount: Int
    let resultingLines: ClosedRange<Int>
    let lineDelta: Int
    let lineEndingStyle: LocalFileLineEndingStyle
    let replacementWasMultiline: Bool
}

enum LocalFileEditFailure: Error, Sendable {
    case emptyOld
    case notFound
    case ambiguous(Int)
}

enum LocalFileEditSupport {
    static func apply(old: String, new: String, to contents: String) throws -> LocalFileEditResult {
        guard !old.isEmpty else {
            throw LocalFileEditFailure.emptyOld
        }

        let style = lineEndingStyle(in: contents)
        var matchedOld = old
        var matches = overlappingRanges(of: matchedOld, in: contents)
        if matches.isEmpty, let separator = style.separator {
            let adaptedOld = adaptingLineEndings(in: old, to: separator)
            if adaptedOld != old {
                matchedOld = adaptedOld
                matches = overlappingRanges(of: matchedOld, in: contents)
            }
        }

        guard !matches.isEmpty else {
            throw LocalFileEditFailure.notFound
        }
        guard matches.count == 1 else {
            throw LocalFileEditFailure.ambiguous(matches.count)
        }

        let range = matches[0]
        let adaptedNew: String
        if let separator = style.separator {
            adaptedNew = adaptingLineEndings(in: new, to: separator)
        } else {
            adaptedNew = new
        }

        let originalLine = lineNumber(at: range.lowerBound, in: contents)
        let originalLineCount = max(1, logicalLineBreakCount(in: matchedOld) + 1)
        let newLineCount = max(1, logicalLineBreakCount(in: adaptedNew) + 1)
        let lineDelta = logicalLineBreakCount(in: adaptedNew) - logicalLineBreakCount(in: matchedOld)
        var updated = contents
        updated.replaceSubrange(range, with: adaptedNew)
        let resultingUpperLine = max(originalLine, originalLine + newLineCount - 1)

        return LocalFileEditResult(
            contents: updated,
            replacedRange: range,
            originalLine: originalLine,
            originalLineCount: originalLineCount,
            resultingLines: originalLine...resultingUpperLine,
            lineDelta: lineDelta,
            lineEndingStyle: style,
            replacementWasMultiline: originalLineCount > 1 || newLineCount > 1
        )
    }

    static func lineEndingStyle(in contents: String) -> LocalFileLineEndingStyle {
        var crlf = 0
        var lf = 0
        var cr = 0
        let bytes = Array(contents.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    crlf += 1
                    index += 2
                    continue
                }
                cr += 1
            } else if bytes[index] == 0x0A {
                lf += 1
            }
            index += 1
        }
        let present = [crlf, lf, cr].filter { $0 > 0 }.count
        guard present > 0 else { return .none }
        guard present == 1 else { return .mixed }
        if crlf > 0 { return .crlf }
        if lf > 0 { return .lf }
        return .cr
    }

    static func overlappingRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            result.append(range)
            searchStart = haystack.index(after: range.lowerBound)
        }
        return result
    }

    static func adaptingLineEndings(in value: String, to separator: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: separator)
    }

    static func logicalLines(in contents: String) -> [String] {
        adaptingLineEndings(in: contents, to: "\n")
            .components(separatedBy: "\n")
    }

    private static func lineNumber(at index: String.Index, in contents: String) -> Int {
        1 + logicalLineBreakCount(in: String(contents[..<index]))
    }

    private static func logicalLineBreakCount(in value: String) -> Int {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }
}

enum LocalFileEditFeedback {
    static func single(path: String) -> String {
        "Updated \(path). Replacements: 1."
    }

    static func multiple(path: String, editCount: Int) -> String {
        "Updated \(path). Edits: \(editCount)."
    }
}
