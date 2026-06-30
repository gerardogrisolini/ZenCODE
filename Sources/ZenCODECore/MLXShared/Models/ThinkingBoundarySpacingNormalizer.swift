//
//  ThinkingBoundarySpacingNormalizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated struct ThinkingBoundarySpacingNormalizer: Sendable {
    private static let closingMarkers = [
        "</think>",
        "</thinking>",
        "<channel|>"
    ]
    private static let thinkingOpeningMarkers = [
        "<|channel>thought",
        "<think>",
        "<thinking>"
    ]

    private var pendingPartialMarker = ""
    private var awaitingResponseBoundary = false
    private var pendingInitialThinkingOpening: Bool
    private var initialThinkingBoundaryOpen = false
    private var initialThinkingClosingMarker = "</think>"
    private var suppressNextLeadingOpeningNewline = false

    public init(startsInThinking: Bool = false) {
        pendingInitialThinkingOpening = startsInThinking
    }

    public mutating func append(_ chunk: String) -> String {
        guard !chunk.isEmpty else {
            return ""
        }

        let combinedText = pendingPartialMarker + chunk
        pendingPartialMarker = ""

        let holdCount = Self.partialMarkerSuffixLength(in: combinedText)
        let processEnd = combinedText.index(
            combinedText.endIndex,
            offsetBy: -holdCount
        )
        let processText = String(combinedText[..<processEnd])
        pendingPartialMarker = String(combinedText[processEnd...])

        return processCompleteText(processText)
    }

    public mutating func finish() -> String {
        var output = processCompleteText(pendingPartialMarker)
        pendingPartialMarker = ""
        if initialThinkingBoundaryOpen {
            output += initialThinkingClosingMarker
            initialThinkingBoundaryOpen = false
            awaitingResponseBoundary = true
        }
        return output
    }

    public static func normalized(
        _ text: String,
        startsInThinking: Bool = false
    ) -> String {
        var normalizer = Self(startsInThinking: startsInThinking)
        return normalizer.append(text) + normalizer.finish()
    }

    private mutating func processCompleteText(_ text: String) -> String {
        let text = textWithoutSuppressedLeadingOpeningNewline(text)
        guard !text.isEmpty else {
            return ""
        }

        var output = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let marker = Self.nextClosingMarker(in: text, from: cursor) else {
                let tail = String(text[cursor...])
                let normalizedTail = textWithInitialThinkingOpeningIfNeeded(tail)
                output += responseText(normalizedTail)
                break
            }

            let contentBeforeMarker = String(text[cursor..<marker.range.lowerBound])
            let normalizedContentBeforeMarker =
                textWithInitialThinkingOpeningIfNeeded(contentBeforeMarker)
            output += responseText(normalizedContentBeforeMarker)
            output += initialThinkingOpeningIfNeeded(beforeClosingMarker: marker.text)
            output += marker.text
            if Self.isThinkingClosingMarker(marker.text) {
                initialThinkingBoundaryOpen = false
            }
            awaitingResponseBoundary = true
            cursor = marker.range.upperBound
        }

        return output
    }

    private mutating func initialThinkingOpeningIfNeeded(
        beforeClosingMarker closingMarker: String
    ) -> String {
        guard pendingInitialThinkingOpening,
              let openingMarker = Self.openingMarker(forClosingMarker: closingMarker) else {
            return ""
        }

        pendingInitialThinkingOpening = false
        initialThinkingBoundaryOpen = true
        initialThinkingClosingMarker = closingMarker
        return textWithThinkingOpeningNewlineIfNeeded(openingMarker)
    }

    private mutating func textWithInitialThinkingOpeningIfNeeded(_ text: String) -> String {
        if Self.containsThinkingOpening(in: text) {
            if let openingMarker = Self.leadingThinkingOpeningMarker(in: text),
               pendingInitialThinkingOpening {
                pendingInitialThinkingOpening = false
                initialThinkingBoundaryOpen = true
                initialThinkingClosingMarker = Self.closingMarker(
                    forOpeningMarker: openingMarker
                )
            }
        }

        guard pendingInitialThinkingOpening, !text.isEmpty else {
            return text
        }

        if let openingMarker = Self.leadingThinkingOpeningMarker(in: text) {
            pendingInitialThinkingOpening = false
            initialThinkingBoundaryOpen = true
            initialThinkingClosingMarker = Self.closingMarker(
                forOpeningMarker: openingMarker
            )
            return textWithThinkingOpeningNewlineIfNeeded(text)
        }

        pendingInitialThinkingOpening = false
        initialThinkingBoundaryOpen = true
        initialThinkingClosingMarker = "</think>"
        return textWithThinkingOpeningNewlineIfNeeded("<think>" + text)
    }

    private mutating func responseText(_ text: String) -> String {
        guard awaitingResponseBoundary else {
            return textWithThinkingOpeningNewlineIfNeeded(text)
        }
        return responseTextAfterBoundary(text)
    }

    private mutating func responseTextAfterBoundary(_ text: String) -> String {
        guard let firstResponseIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }

        awaitingResponseBoundary = false
        return "\n\n" + String(text[firstResponseIndex...])
    }

    private static func nextClosingMarker(
        in text: String,
        from cursor: String.Index
    ) -> (range: Range<String.Index>, text: String)? {
        let searchRange = cursor..<text.endIndex
        return closingMarkers
            .compactMap { marker in
                text.range(of: marker, range: searchRange).map { range in
                    (range: range, text: marker)
                }
            }
            .min { lhs, rhs in
                lhs.range.lowerBound < rhs.range.lowerBound
            }
    }

    private static func containsThinkingOpening(in text: String) -> Bool {
        thinkingOpeningMarkers.contains { text.contains($0) }
    }

    private mutating func textWithThinkingOpeningNewlineIfNeeded(_ text: String) -> String {
        guard Self.containsThinkingOpening(in: text) else {
            return text
        }

        var output = text
        var searchStart = output.startIndex
        while let opening = Self.nextOpeningMarker(in: output, from: searchStart) {
            let contentStart = opening.range.upperBound
            while contentStart < output.endIndex,
                  output[contentStart].isWhitespace {
                output.remove(at: contentStart)
            }

            if contentStart == output.endIndex {
                output.insert("\n", at: contentStart)
                suppressNextLeadingOpeningNewline = true
            } else {
                output.insert("\n", at: contentStart)
                suppressNextLeadingOpeningNewline = false
            }
            searchStart = output.index(after: contentStart)
        }

        return output
    }

    private mutating func textWithoutSuppressedLeadingOpeningNewline(_ text: String) -> String {
        guard suppressNextLeadingOpeningNewline, !text.isEmpty else {
            return text
        }

        suppressNextLeadingOpeningNewline = false
        guard let first = text.first, first.isNewline else {
            return text
        }
        return String(text.drop(while: \.isNewline))
    }

    private static func isThinkingClosingMarker(_ marker: String) -> Bool {
        marker == "</think>" || marker == "</thinking>" || marker == "<channel|>"
    }

    private static func leadingThinkingOpeningMarker(in text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return thinkingOpeningMarkers.first { trimmedText.hasPrefix($0) }
    }

    private static func nextOpeningMarker(
        in text: String,
        from cursor: String.Index
    ) -> (range: Range<String.Index>, text: String)? {
        let searchRange = cursor..<text.endIndex
        return thinkingOpeningMarkers
            .compactMap { marker in
                text.range(of: marker, range: searchRange).map { range in
                    (range: range, text: marker)
                }
            }
            .min { lhs, rhs in
                lhs.range.lowerBound < rhs.range.lowerBound
            }
    }

    private static func closingMarker(forOpeningMarker openingMarker: String) -> String {
        switch openingMarker {
        case "<|channel>thought":
            return "<channel|>"
        case "<thinking>":
            return "</thinking>"
        default:
            return "</think>"
        }
    }

    private static func openingMarker(forClosingMarker closingMarker: String) -> String? {
        switch closingMarker {
        case "<channel|>":
            return "<|channel>thought"
        case "</thinking>":
            return "<thinking>"
        case "</think>":
            return "<think>"
        default:
            return nil
        }
    }

    private static func partialMarkerSuffixLength(in text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        var bestLength = 0
        for marker in closingMarkers + thinkingOpeningMarkers {
            let maximumLength = min(text.count, marker.count - 1)
            guard maximumLength > 0 else {
                continue
            }

            for length in stride(from: maximumLength, through: 1, by: -1) {
                let suffixStart = text.index(text.endIndex, offsetBy: -length)
                let suffix = String(text[suffixStart...])
                if marker.hasPrefix(suffix) {
                    bestLength = max(bestLength, length)
                    break
                }
            }
        }

        return bestLength
    }
}
