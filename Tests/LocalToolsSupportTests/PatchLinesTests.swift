import Testing
@testable import LocalToolsSupport

@Suite
struct PatchLinesTests {
    // MARK: - split

    @Test
    func splitsLfTextAtEveryLineFeed() {
        #expect(PatchLines.split("a\nb\nc") == ["a", "b", "c"])
    }

    @Test
    func splitsCrlfTextAndKeepsTheCarriageReturnInsideTheLines() {
        #expect(PatchLines.split("a\r\nb\r\nc") == ["a\r", "b\r", "c"])
    }

    @Test
    func splitsMixedLineEndingsAtLineFeedsOnly() {
        #expect(PatchLines.split("a\r\nb\nc\r") == ["a\r", "b", "c\r"])
        #expect(PatchLines.split("a\rb\n") == ["a\rb", ""])
    }

    @Test
    func aFinalLineFeedYieldsAFinalEmptyLine() {
        #expect(PatchLines.split("a\nb\n") == ["a", "b", ""])
        #expect(PatchLines.split("a\r\nb\r\n") == ["a\r", "b\r", ""])
        #expect(PatchLines.split("\n") == ["", ""])
    }

    @Test
    func emptyStringYieldsOneEmptyLine() {
        #expect(PatchLines.split("") == [""])
    }

    @Test
    func textWithoutLineFeedIsASingleLine() {
        #expect(PatchLines.split("abc") == ["abc"])
        #expect(PatchLines.split("abc\r") == ["abc\r"])
    }

    @Test
    func consecutiveLineFeedsKeepTheEmptyLinesBetweenThem() {
        #expect(PatchLines.split("a\n\nb") == ["a", "", "b"])
        #expect(PatchLines.split("a\r\n\r\nb") == ["a\r", "\r", "b"])
    }

    @Test
    func nonAsciiContentIsKeptIntact() {
        #expect(PatchLines.split("é\r\n日本語\n😀") == ["é\r", "日本語", "😀"])
    }

    @Test
    func joiningTheLinesWithLineFeedRestoresTheTextByteForByte() {
        let samples = ["", "\n", "a", "a\n", "a\r\nb\r\n", "a\r\nb\nc\r", "\r\n\r\n", "é\r\n😀\n\n"]

        for sample in samples {
            #expect(Array(PatchLines.split(sample).joined(separator: "\n").utf8) == Array(sample.utf8))
        }
    }

    // MARK: - withoutTrailingCarriageReturn

    @Test
    func dropsExactlyOneTrailingCarriageReturn() {
        #expect(PatchLines.withoutTrailingCarriageReturn("a\r") == "a")
        #expect(PatchLines.withoutTrailingCarriageReturn("\r") == "")
        #expect(PatchLines.withoutTrailingCarriageReturn("a\r\r") == "a\r")
    }

    @Test
    func leavesLinesWithoutATrailingCarriageReturnUntouched() {
        #expect(PatchLines.withoutTrailingCarriageReturn("") == "")
        #expect(PatchLines.withoutTrailingCarriageReturn("a") == "a")
        #expect(PatchLines.withoutTrailingCarriageReturn("a\rb") == "a\rb")
        #expect(PatchLines.withoutTrailingCarriageReturn("\ra") == "\ra")
    }

    // MARK: - endsWithLineFeed

    @Test
    func detectsAFinalLineFeedForLfAndCrlfText() {
        #expect(PatchLines.endsWithLineFeed("a\n"))
        #expect(PatchLines.endsWithLineFeed("a\r\n"))
        #expect(PatchLines.endsWithLineFeed("\n"))
        #expect(PatchLines.endsWithLineFeed("a\r\nb\r\n"))
    }

    @Test
    func reportsNoFinalLineFeedOtherwise() {
        #expect(!PatchLines.endsWithLineFeed(""))
        #expect(!PatchLines.endsWithLineFeed("a"))
        #expect(!PatchLines.endsWithLineFeed("a\r"))
        #expect(!PatchLines.endsWithLineFeed("a\nb"))
        #expect(!PatchLines.endsWithLineFeed("a\r\nb\r"))
    }
}
