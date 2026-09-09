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

    @Test
    func streamsWordsWithoutInsertingFragmentSeparators() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("*") == "")
        #expect(normalizer.consume("*Ridu") == "Ridu")
        #expect(normalizer.consume("co il problema") == "co il problema")
        #expect(normalizer.consume("*") == "")
        #expect(normalizer.consume("*") == "")
        #expect(normalizer.finish() == "")
        #expect(normalizer.finish() == "")
        #expect(normalizer.consume("pro") == "pro")
        #expect(normalizer.consume("blema") == "blema")
        #expect(normalizer.finish() == "")
    }

    @Test(arguments: ["", " ", "\t ", "\n", "\n\n", "\r\n\r\n", " \r\n \t"])
    func existingSeparatorsAreNotDuplicated(separator: String) {
        #expect(normalize(["**Titolo**", separator, "**Altro**", separator])
            == "Titolo\nAltro")
    }

    @Test
    func singlesUnclosedDelimitersAndPlainTextDoNotInventBoundaries() {
        #expect(normalize(["un*", "a frase* e **incompleta*"]) == "una frase e incompleta")
        #expect(normalize(["prima ", "frase. ", "Seconda frase."]) == "prima frase. Seconda frase.")
        #expect(normalize(["**Titolo**\r\n", "\r\nTesto"]) == "Titolo\nTesto")
        #expect(normalize(["**Titolo**\r", "\n\r", "\nTesto"]) == "Titolo\nTesto")
        #expect(normalize(["", "*", ""]) == "")
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
        "Verifico **questo caso** prima di procedere.",
        "**Questo caso** resta nella stessa frase.",
        "**Questo caso**\t resta nella stessa frase.",
        "**Questo caso**: continuo.",
        "Verifico **questo caso**",
        "**Inizio** poi testo",
        "Verifico **caso** poi",
        "**Inizio** continua."
    ])
    func inlineBoldNeverAddsParagraphs(source: String) {
        expectAllScalarSegmentations(source, expected: source.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\t ", with: " "))
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

    @Test
    func blockRecognitionIsIndependentOfScalarChunkBoundaries() {
        expectAllScalarSegmentations("**A**", expected: "A")
        expectAllScalarSegmentations("**A****B**", expected: "A\nB")
        expectAllScalarSegmentations("**A**\n**B**", expected: "A\nB")
        expectAllScalarSegmentations("**A**\r\n\r\n**B**", expected: "A\nB")
        expectAllScalarSegmentations("**A**\r\n**B**\r\n\r\n", expected: "A\nB")
        expectAllScalarSegmentations("**A**\nTesto **inline** seguito.", expected: "A\nTesto inline seguito.")
    }

    @Test(arguments: ["**A****", "**A**** **", "**A**\r\n\r\n", "**A** *", "**A**\t "])
    func incompleteOrEmptyFollowingBlocksNeverEmitTrailingSeparators(source: String) {
        expectAllScalarSegmentations(source, expected: "A")
    }

    @Test
    func markerOnlyChunksWaitForActualNextBlockContent() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("**A**") == "A")
        for chunk in ["*", "", "*", " ", "*", "*"] {
            #expect(normalizer.consume(chunk).isEmpty)
        }
        #expect(normalizer.consume("**B**\r\n\r\n") == "\nB")
        #expect(normalizer.finish().isEmpty)
        #expect(normalizer.finish().isEmpty)
        #expect(normalizer.consume("**C**") == "C")
    }

    @Test
    func pendingNewlineTakesPriorityOverWhitespaceUntilContent() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("**A**\r") == "A")
        #expect(normalizer.consume("\n\r\n \t**").isEmpty)
        #expect(normalizer.consume("B**\n") == "\nB")
        #expect(normalizer.finish().isEmpty)
        #expect(normalizer.finish().isEmpty)
        #expect(normalizer.consume("next") == "next")
    }

    @Test
    func closingCandidateWaitsForContentRatherThanChunkEnd() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("**Questo caso**") == "Questo caso")
        #expect(normalizer.consume(" ") == "")
        #expect(normalizer.consume("resta nella stessa frase.") == " resta nella stessa frase.")
        #expect(normalizer.finish() == "")
    }

    @Test
    func finishDiscardsPartialDelimiterStateBetweenSegments() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("**interrotto*") == "interrotto")
        #expect(normalizer.finish() == "")
        #expect(normalizer.consume("**nuovo**") == "nuovo")
        #expect(normalizer.finish() == "")
        #expect(normalizer.finish() == "")
    }

    @Test
    func lineBreaksAndWhitespaceCollapseWithoutForcedReturns() {
        let source = " \r\nPrima\r\n\rSeconda\n\t Terza  **caso** poi\r\n"
        let expected = "Prima Seconda Terza caso poi"
        expectAllScalarSegmentations(source, expected: expected)
        let output = normalize(source.unicodeScalars.map { String($0) })
        #expect(!output.contains("\n"))
        #expect(!output.contains("\r"))
    }

    @Test
    func newlineWaitsForContentAndFinishDiscardsIt() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("**A**") == "A")
        #expect(normalizer.consume("\r") == "")
        #expect(normalizer.consume("\n\r\n \t") == "")
        #expect(normalizer.finish() == "")
        #expect(normalizer.finish() == "")
        #expect(normalizer.consume("**B**") == "B")
        #expect(normalizer.finish() == "")
        #expect(normalizer.consume(" continua") == "continua")
        #expect(normalizer.finish() == "")
    }

    @Test
    func plainSegmentsStartWithoutWhitespaceAfterRepeatedFinish() {
        var normalizer = ACPChatGPTThoughtNormalizer()
        #expect(normalizer.consume("Verifico **caso** poi") == "Verifico caso poi")
        #expect(normalizer.finish() == "")
        #expect(normalizer.finish() == "")
        #expect(normalizer.consume(" **Inizio** continua.") == "Inizio continua.")
        #expect(normalizer.finish() == "")
    }

    @Test(arguments: ["", " ", "\r\n\t "])
    func finishedTitleSegmentsStartAndEndWithoutWhitespace(whitespace: String) {
        var normalizer = ACPChatGPTThoughtNormalizer()
        var output = normalizer.consume("**A**" + whitespace)
        output += normalizer.finish()
        #expect(output == "A")
        #expect(normalizer.finish() == "")
        output = normalizer.consume(whitespace + "**B**" + whitespace)
        output += normalizer.finish()
        #expect(output == "B")
        #expect(normalizer.finish() == "")
    }
}
