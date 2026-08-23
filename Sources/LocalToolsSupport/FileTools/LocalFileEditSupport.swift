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

struct LocalFileEditSummary: Sendable {
    var oldLine: Int
    var resultingLines: ClosedRange<Int>
    let lineDelta: Int
    let multiline: Bool
}

enum LocalFileEditFeedback {
    static func single(path: String, result: LocalFileEditResult) -> String {
        let summary = LocalFileEditSummary(
            oldLine: result.originalLine,
            resultingLines: result.resultingLines,
            lineDelta: result.lineDelta,
            multiline: result.replacementWasMultiline
        )
        return render(
            path: path,
            contents: result.contents,
            summaries: [summary],
            multi: false,
            maximumLines: result.replacementWasMultiline ? 16 : 8,
            maximumBytes: result.replacementWasMultiline ? 3_072 : 2_048
        )
    }

    static func multiple(path: String, contents: String, summaries: [LocalFileEditSummary]) -> String {
        render(
            path: path,
            contents: contents,
            summaries: summaries,
            multi: true,
            maximumLines: 24,
            maximumBytes: 4_096
        )
    }

    private static func render(
        path: String,
        contents: String,
        summaries: [LocalFileEditSummary],
        multi: Bool,
        maximumLines: Int,
        maximumBytes: Int
    ) -> String {
        let fileLines = LocalFileEditSupport.logicalLines(in: contents)
        var output: [String] = [
            multi
                ? "Updated \(path). Edits: \(summaries.count)."
                : "Updated \(path). Replacements: 1."
        ]

        let summaryBudget = multi ? min(summaries.count, 8) : summaries.count
        for (index, summary) in summaries.prefix(summaryBudget).enumerated() {
            let prefix = multi ? "Edit \(index + 1): " : ""
            output.append("\(prefix)old line \(summary.oldLine); resulting lines \(summary.resultingLines.lowerBound)-\(summary.resultingLines.upperBound); line shift: \(summary.lineDelta).")
        }
        if summaries.count > summaryBudget {
            output.append("... \(summaries.count - summaryBudget) edit summaries omitted ...")
        }

        let contextBudget = max(0, maximumLines - output.count - 1)
        let windows = mergedWindows(for: summaries, lineCount: fileLines.count)
        let selected = selectedLineNumbers(from: windows, budget: contextBudget)
        if let first = selected.first, let last = selected.last {
            output.append("Current file around edits: lines \(first)-\(last) of \(fileLines.count)")
            var previous: Int?
            for lineNumber in selected {
                if let previous, lineNumber > previous + 1 {
                    output.append("... \(lineNumber - previous - 1) lines omitted ...")
                }
                guard output.count < maximumLines else { break }
                output.append("\(lineNumber)\t\(fileLines[lineNumber - 1])")
                previous = lineNumber
            }
        }
        return constrained(output, maximumLines: maximumLines, maximumBytes: maximumBytes)
    }

    private static func mergedWindows(
        for summaries: [LocalFileEditSummary],
        lineCount: Int
    ) -> [ClosedRange<Int>] {
        let sorted = summaries.map { summary in
            let before = summary.multiline ? 3 : 2
            let after = summary.multiline ? 4 : 3
            return max(1, summary.resultingLines.lowerBound - before)...min(
                lineCount,
                summary.resultingLines.upperBound + after
            )
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for window in sorted {
            if let last = merged.last, window.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    private static func selectedLineNumbers(
        from windows: [ClosedRange<Int>],
        budget: Int
    ) -> [Int] {
        guard budget > 0 else { return [] }
        let all = windows.flatMap { Array($0) }
        guard all.count > budget else { return all }
        let headCount = max(1, budget / 2)
        let tailCount = max(0, budget - headCount)
        return Array(all.prefix(headCount)) + Array(all.suffix(tailCount))
    }

    private static func constrained(
        _ lines: [String],
        maximumLines: Int,
        maximumBytes: Int
    ) -> String {
        var result: [String] = []
        var usedBytes = 0
        for line in lines.prefix(maximumLines) {
            let separatorBytes = result.isEmpty ? 0 : 1
            let available = maximumBytes - usedBytes - separatorBytes
            guard available > 0 else { break }
            let fitted = utf8Prefix(line, maximumBytes: available)
            guard !fitted.isEmpty else { break }
            result.append(fitted)
            usedBytes += separatorBytes + fitted.utf8.count
            if fitted != line { break }
        }
        return result.joined(separator: "\n")
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > 3 else { return String(repeating: ".", count: maximumBytes) }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            if candidate.utf8.count + 3 > maximumBytes { break }
            result = candidate
        }
        return result + "..."
    }
}
