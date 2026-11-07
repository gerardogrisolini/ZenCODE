import Testing
@testable import LocalToolsSupport

@Suite
struct PatchLinesTests {
    // MARK: - split

    @Test
    func joiningTheLinesWithLineFeedRestoresTheTextByteForByte() {
        let samples = ["", "\n", "a", "a\n", "a\r\nb\r\n", "a\r\nb\nc\r", "\r\n\r\n", "é\r\n😀\n\n"]

        for sample in samples {
            #expect(Array(PatchLines.split(sample).joined(separator: "\n").utf8) == Array(sample.utf8))
        }
    }
}
