import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

/// The exact `InputRichBlock` wire the Telegram adapter derives from the
/// presentation tree. Keys are sorted so each expectation is one literal.
@Suite
struct TerminalTelegramRichBlockTests {

    // MARK: - Existing blocks (characterization)

    @Test
    func messageEnvelopeSkipsEntityDetectionAndOmitsDirection() throws {
        let message = try TerminalTelegramRichMessageRenderer.render(PresentationDocument(markdown: "World"))
        #expect(try json(message) == #"{"blocks":[{"text":"World","type":"paragraph"}],"skip_entity_detection":true}"#)
    }

    @Test
    func headingCarriesItsSizeBeforeAParagraph() throws {
        #expect(try wire("# Title\n\n### Small\n\nWorld") == #"""
        [{"size":1,"text":"Title","type":"heading"},{"size":3,"text":"Small","type":"heading"},\#
        {"text":"World","type":"paragraph"}]
        """#)
    }

    @Test
    func codeBlockBecomesPreWithItsLanguage() throws {
        #expect(try wire("```swift\nlet x = 1\n```\n\n```\nplain\n```") == #"""
        [{"language":"swift","text":"let x = 1","type":"pre"},{"text":"plain","type":"pre"}]
        """#)
    }

    @Test
    func unorderedListItemsCarryOnlyTheirBlocks() throws {
        #expect(try wire("- a\n- b") == #"""
        [{"items":[{"blocks":[{"text":"a","type":"paragraph"}]},{"blocks":[{"text":"b","type":"paragraph"}]}],\#
        "type":"list"}]
        """#)
    }

    @Test
    func orderedListItemsAreNumberedWithDecimalType() throws {
        #expect(try wire("1. a\n2. b") == #"""
        [{"items":[{"blocks":[{"text":"a","type":"paragraph"}],"type":"1","value":1},\#
        {"blocks":[{"text":"b","type":"paragraph"}],"type":"1","value":2}],"type":"list"}]
        """#)
    }

    @Test
    func inlineStylesBecomeStyledRichTexts() throws {
        #expect(try wire("`code` *it* **bold** [link](https://example.com/a)") == #"""
        [{"text":[{"text":"code","type":"code"}," ",{"text":"it","type":"italic"}," ",\#
        {"text":"bold","type":"bold"}," ",{"text":"link","type":"url","url":"https://example.com/a"}],\#
        "type":"paragraph"}]
        """#)
    }

    @Test
    func nestedStylesNestTheirRichTexts() throws {
        #expect(try wire("**bold *both***") == #"""
        [{"text":{"text":["bold ",{"text":"both","type":"italic"}],"type":"bold"},"type":"paragraph"}]
        """#)
    }

    // MARK: - New blocks

    @Test
    func tableSendsEveryCellWithAlignmentHeaderAndEmptyText() throws {
        let markdown = """
        | Name | Qty | Note | Plain |
        |:-----|:---:|-----:|-------|
        | a | **1** |  | z |
        """
        let wire = try wire(markdown)
        #expect(wire == #"""
        [{"cells":[[{"align":"left","is_header":true,"text":"Name","valign":"top"},\#
        {"align":"center","is_header":true,"text":"Qty","valign":"top"},\#
        {"align":"right","is_header":true,"text":"Note","valign":"top"},\#
        {"align":"left","is_header":true,"text":"Plain","valign":"top"}],\#
        [{"align":"left","text":"a","valign":"top"},\#
        {"align":"center","text":{"text":"1","type":"bold"},"valign":"top"},\#
        {"align":"right","text":"","valign":"top"},\#
        {"align":"left","text":"z","valign":"top"}]],\#
        "is_bordered":true,"is_compact":true,"type":"table"}]
        """#)
        #expect(!wire.contains("false"))
    }

    @Test
    func raggedTableRowIsPaddedWithEmptyCells() throws {
        var document = PresentationDocument(markdown: "")
        document.blocks = [.table(PresentationTable(
            alignments: [.left, .right],
            header: [plain("h1"), plain("h2")],
            rows: [[plain("only")]]
        ))]
        let blocks = try TerminalTelegramRichMessageRenderer.render(document).blocks
        #expect(try json(blocks) == #"""
        [{"cells":[[{"align":"left","is_header":true,"text":"h1","valign":"top"},\#
        {"align":"right","is_header":true,"text":"h2","valign":"top"}],\#
        [{"align":"left","text":"only","valign":"top"},{"align":"right","text":"","valign":"top"}]],\#
        "is_bordered":true,"is_compact":true,"type":"table"}]
        """#)
    }

    @Test
    func quotationNestsItsBlocks() throws {
        #expect(try wire("> quoted\n>\n> - item\n>\n> ```\n> code\n> ```") == #"""
        [{"blocks":[{"text":"quoted","type":"paragraph"},\#
        {"items":[{"blocks":[{"text":"item","type":"paragraph"}]}],"type":"list"},\#
        {"text":"code","type":"pre"}],"type":"blockquote"}]
        """#)
    }

    @Test
    func thematicBreakBecomesDivider() throws {
        #expect(try wire("before\n\n---\n\nafter") == #"""
        [{"text":"before","type":"paragraph"},{"type":"divider"},{"text":"after","type":"paragraph"}]
        """#)
    }

    @Test
    func taskItemsCarryTheirCheckboxAndOnlyTrueFlags() throws {
        let wire = try wire("- [ ] todo\n- [x] done\n- plain")
        #expect(wire == #"""
        [{"items":[{"blocks":[{"text":"todo","type":"paragraph"}],"has_checkbox":true},\#
        {"blocks":[{"text":"done","type":"paragraph"}],"has_checkbox":true,"is_checked":true},\#
        {"blocks":[{"text":"plain","type":"paragraph"}]}],"type":"list"}]
        """#)
        #expect(!wire.contains("false"))
    }

    @Test
    func orderedListValuesCountFromItsStart() throws {
        #expect(try wire("7. seven\n8. [x] eight") == #"""
        [{"items":[{"blocks":[{"text":"seven","type":"paragraph"}],"type":"1","value":7},\#
        {"blocks":[{"text":"eight","type":"paragraph"}],"has_checkbox":true,"is_checked":true,\#
        "type":"1","value":8}],"type":"list"}]
        """#)
    }

    @Test
    func orderedListValueKeepsTheNumberOfAnItemAfterAnEmptyOne() throws {
        var document = PresentationDocument(markdown: "")
        document.blocks = [.list(PresentationList(kind: .ordered(start: 2), items: [
            PresentationListItem(blocks: []),
            PresentationListItem(blocks: [.paragraph(plain("three"))]),
        ]))]
        #expect(try json(TerminalTelegramRichMessageRenderer.render(document).blocks) == #"""
        [{"items":[{"blocks":[{"text":"three","type":"paragraph"}],"type":"1","value":3}],"type":"list"}]
        """#)
    }

    @Test
    func strikethroughIsAStyledRichText() throws {
        #expect(try wire("~~gone~~ kept") == #"""
        [{"text":[{"text":"gone","type":"strikethrough"}," kept"],"type":"paragraph"}]
        """#)
    }

    // MARK: - Degradation

    @Test
    func tableWithMoreThanTwentyColumnsBecomesPreWithItsPlainText() throws {
        let header = (1...21).map { "c\($0)" }.joined(separator: " | ")
        let row = (1...21).map { "v\($0)" }.joined(separator: " | ")
        #expect(try wire(table(columns: 21)) == #"[{"text":"\#(header)\n\#(row)","type":"pre"}]"#)

        let widest = try wire(table(columns: 20))
        #expect(widest.hasPrefix(#"[{"cells":"#))
        #expect(widest.hasSuffix(#""type":"table"}]"#))
    }

    @Test
    func quotationsBeyondTheNestingLimitFlattenWithoutLosingText() throws {
        let blocks = try decodedBlocks(String(repeating: "> ", count: 20) + "deep **bold**")
        #expect(objectDepth(blocks) == TerminalTelegramRichMessageRenderer.maximumNestingDepth)
        #expect(texts(in: blocks) == [String(repeating: "> ", count: 9) + "deep bold"])
    }

    @Test
    func listsBeyondTheNestingLimitFlattenWithoutLosingText() throws {
        let markdown = (1...8).map { String(repeating: "  ", count: $0 - 1) + "- l\($0)" }.joined(separator: "\n")
        let blocks = try decodedBlocks(markdown)
        #expect(objectDepth(blocks) <= TerminalTelegramRichMessageRenderer.maximumNestingDepth)
        #expect(texts(in: blocks) == ["l1", "l2", "l3", "l4", "l5", "• l6\n• l7\n• l8"])
    }

    @Test
    func stylesBeyondTheNestingLimitFlattenWithoutLosingText() throws {
        var text = PresentationText(runs: [.plain("core")])
        for _ in 0..<15 { text = PresentationText(runs: [.emphasis(text)]) }
        var document = PresentationDocument(markdown: "")
        document.blocks = [.paragraph(text)]
        let blocks = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TerminalTelegramRichMessageRenderer.render(document).blocks)
        )
        #expect(objectDepth(blocks) == TerminalTelegramRichMessageRenderer.maximumNestingDepth)
        #expect(texts(in: blocks) == ["core"])
    }

    // MARK: - Helpers

    private func plain(_ text: String) -> PresentationText {
        PresentationText(runs: [.plain(text)])
    }

    private func table(columns: Int) -> String {
        let header = (1...columns).map { "c\($0)" }.joined(separator: " | ")
        let delimiter = Array(repeating: "---", count: columns).joined(separator: " | ")
        let row = (1...columns).map { "v\($0)" }.joined(separator: " | ")
        return "| \(header) |\n| \(delimiter) |\n| \(row) |"
    }

    private func decodedBlocks(_ markdown: String) throws -> Any {
        let message = try TerminalTelegramRichMessageRenderer.render(PresentationDocument(markdown: markdown))
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(message.blocks))
    }

    /// The deepest chain of nested JSON objects: blocks, list items, table
    /// cells, and styled texts each count as one level.
    private func objectDepth(_ value: Any) -> Int {
        if let object = value as? [String: Any] { return 1 + (object.values.map(objectDepth).max() ?? 0) }
        if let array = value as? [Any] { return array.map(objectDepth).max() ?? 0 }
        return 0
    }

    /// Every string held under a `text` key, in document order.
    private func texts(in value: Any) -> [String] {
        if let array = value as? [Any] { return array.flatMap { texts(in: $0) } }
        guard let object = value as? [String: Any] else { return [] }
        return object.keys.sorted().flatMap { key in
            key == "text" ? richTexts(object[key] as Any) : texts(in: object[key] as Any)
        }
    }

    private func richTexts(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap { richTexts($0) } }
        return texts(in: value)
    }

    private func wire(_ markdown: String) throws -> String {
        try json(TerminalTelegramRichMessageRenderer.render(PresentationDocument(markdown: markdown)).blocks)
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
