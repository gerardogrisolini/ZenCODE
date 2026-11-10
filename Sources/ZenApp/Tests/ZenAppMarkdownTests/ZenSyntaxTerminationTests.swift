import Testing
import ZenAppMarkdown

/// A `$` inside a markup tag starts an identifier but not a markup name: it
/// once left the markup scanner on the same position forever.
@Suite
struct ZenSyntaxTerminationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["html", "xml"])
    func dollarInsideATagTerminatesAndTheTokensReproduceTheInput(_ language: String) {
        for code in ["<a $x>", "<a $>", "<a $"] {
            let tokens = ZenSyntaxHighlighter.highlight(code, language: language)
            let text = tokens.map { $0.text }.joined()
            #expect(text == code, "\(language): \(code)")
        }
    }
}
