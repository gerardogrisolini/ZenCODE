import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ACPChatGPTThoughtNormalizerTests {
    private func normalize(_ chunks: [String]) -> String {
        var normalizer = ACPChatGPTThoughtNormalizer()
        var text = ""
        for chunk in chunks {
            text += normalizer.consume(chunk)
            #expect(text.unicodeScalars.last?.properties.isWhitespace != true)
        }
        let end = normalizer.finish()
        #expect(end.isEmpty)
        return text + end
    }

    @Test
    func everyPairOfChunkBoundariesPreservesFormatting() {
        let source = Array("**Riduco il problema a sottoinsiemi****Verifico**\n\nPoi *confronto*.")
        let expected = "Riduco il problema a sottoinsiemi\nVerifico\nPoi confronto."
        for first in 0...source.count {
            for second in first...source.count {
                let chunks = [String(source[..<first]), String(source[first..<second]),
                              String(source[second...])]
                #expect(normalize(chunks) == expected)
            }
        }
        #expect(normalize(source.map(String.init)) == expected)
    }

    @Test(arguments: ["", " ", "\t ", "\n", "\n\n", "\r\n\r\n", " \r\n \t"])
    func existingSeparatorsAreNotDuplicated(separator: String) {
        #expect(normalize(["**Titolo**", separator, "**Altro**", separator])
            == "Titolo\nAltro")
    }

    /// Exercise scalar boundaries too: Character boundaries hide the regression
    /// where an asterisk and a combining accent form a single grapheme.
    private func expectAllScalarSegmentations(_ source: String, expected: String) {
        let scalars = Array(source.unicodeScalars)
        func text(_ range: ArraySlice<Unicode.Scalar>) -> String {
            String(String.UnicodeScalarView(range))
        }
        #expect(normalize([source]) == expected)
        for first in 0...scalars.count {
            for second in first...scalars.count {
                #expect(normalize([
                    text(scalars[..<first]), text(scalars[first..<second]),
                    text(scalars[second...])
                ]) == expected)
            }
        }
        #expect(normalize(scalars.map { String($0) }) == expected)
    }

    @Test(arguments: [
        "Calcolo 2**3 e poi 4**2.\n**Titolo**",
        "Calcolo 2**3.\n**Titolo**",
        "`2**3`\n**Titolo**",
        "`**codice**`\n**Titolo**",
        "**incompleto\n**Titolo**"
    ])
    func literalAndUnmatchedPairsDoNotDesynchronizeLaterBlocks(source: String) {
        expectAllScalarSegmentations(
            source, expected: source.replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "\n", with: " ")
        )
    }

    @Test
    func scalarRemovalPreservesCombiningMarksAcrossChunkBoundaries() {
        expectAllScalarSegmentations("a*\u{0301}b", expected: "a\u{0301}b")
        expectAllScalarSegmentations("*\u{0301}**Titolo**", expected: "\u{0301}Titolo")
        expectAllScalarSegmentations("**A*\u{0301}B**", expected: "A\u{0301}B")
        expectAllScalarSegmentations("*\u{0301}\n**A****B**", expected: "\u{0301} A\nB")
        expectAllScalarSegmentations("**Caffè 👩🏽‍💻****日本語**", expected: "Caffè 👩🏽‍💻\n日本語")
    }
}
