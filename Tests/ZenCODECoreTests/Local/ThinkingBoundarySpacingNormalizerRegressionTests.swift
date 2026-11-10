//
//  ThinkingBoundarySpacingNormalizerRegressionTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

/// Regressions of the whitespace removal after an opening marker. It kept an
/// index across the mutation of the text: when a character of two or more
/// UTF-8 bytes followed the marker, directly or after the removed whitespace,
/// the stale index trapped or corrupted the output.
@Suite
struct ThinkingBoundarySpacingNormalizerRegressionTests {
    @Test
    func multibyteCharacterAfterAnOpeningMarkerDoesNotTrap() async {
        await Task.yield()
        Self.expect(["<think>\r\n"], yields: ["<think>\n", ""])
        Self.expect(["<thinking>\r\n"], startsInThinking: true, yields: ["<thinking>\n", "</thinking>"])
        Self.expect(["\r\n a"], startsInThinking: true, yields: ["<think>\na", "</think>"])
        Self.expect(
            ["<", "|channel>thought\r\n", "\nanswer"],
            yields: ["", "<|channel>thought\n", "answer", ""]
        )
        Self.expect(["\u{E9}<chan\r"], startsInThinking: true, yields: ["<think>\n\u{E9}<chan\r", "</think>"])
        Self.expect(
            ["\u{226E}<think>\u{226E}"],
            startsInThinking: true,
            yields: ["<think>\n\u{226E}<think>\n\u{226E}", "</think>"]
        )
    }

    /// Only the whitespace scalars go: the mark a space carries stays, as it
    /// does when the stream splits the space from its mark.
    @Test
    func spaceCarryingACombiningMarkKeepsTheMark() async {
        await Task.yield()
        Self.expect(["<think> \u{301}x"], yields: ["<think>\n\u{301}x", ""])
        Self.expect(["<think> ", "\u{301}x"], yields: ["<think>\n", "\u{301}x", ""])
    }

    /// Inputs that did not trap but lost a character, broke a scalar, or
    /// skipped the newline after a following marker.
    @Test
    func outputsCorruptedWithoutTrappingAreIntact() async {
        await Task.yield()
        Self.expect(["<think>\r\n abc"], yields: ["<think>\nabc", ""])
        Self.expect(["<|channel>thought\r\u{226E}"], yields: ["<|channel>thought\n\u{226E}", ""])
        Self.expect(
            ["<|channel>thought\r\n<|channel>thought"],
            yields: ["<|channel>thought\n<|channel>thought\n", ""]
        )
    }

    /// Compares the streamed pieces and the final flush byte for byte: string
    /// equality would accept canonically equivalent text.
    private static func expect(
        _ chunks: [String],
        startsInThinking: Bool = false,
        yields expected: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var normalizer = ThinkingBoundarySpacingNormalizer(startsInThinking: startsInThinking)
        let pieces = chunks.map { normalizer.append($0) } + [normalizer.finish()]
        #expect(
            pieces.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
            "\(chunks.debugDescription) -> \(pieces.debugDescription)",
            sourceLocation: sourceLocation
        )
    }
}
