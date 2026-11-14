// The exact bytes `TerminalPrimaryScreen` writes for two long deterministic
// streams. Hashes and lengths were captured on the full-relayout code that
// preceded the incremental paragraph layout: never regenerate them for it.
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite struct TerminalPrimaryScreenOutputCharacterizationTests {
    @Test(arguments: [
        (UInt64(1), UInt64(6_832_360_623_231_846_277), 97_231),
        (UInt64(42), UInt64(15_617_485_892_562_263_385), 87_197),
    ] as [(UInt64, UInt64, Int)])
    func streamedBytesMatchTheFullRelayoutCapture(seed: UInt64, hash: UInt64, length: Int) async {
        await Task.yield()
        let bytes = Self.output(seed: seed)
        #expect(bytes.utf8.count == length)
        #expect(Self.fnv1a(bytes) == hash)
    }

    /// Captured on the code that recomputed the modal area on every write:
    /// never regenerate it for the memoized modal sequence.
    @Test func modalBytesMatchThePerWriteRecomputationCapture() async {
        await Task.yield()
        let bytes = Self.modalOutput(seed: 7)
        #expect(bytes.utf8.count == 196_871)
        #expect(Self.fnv1a(bytes) == UInt64(8_340_741_919_495_088_603))
    }

    private static let fragments: [String] = [
        "a", "Z", " ", "hello", "x", "-", "#", "~", "😀", "👍", "👍🏽", "🎉", "⏳", "⌚",
        "中", "漢字", "こ", "Ａ", "한", "e\u{301}", "\u{301}", "a\u{300}\u{302}", "👩‍💻", "👨‍👩‍👧", "\u{200D}",
        "✂\u{FE0F}", "✂", "\u{FE0F}", "⏳\u{FE0E}", "\u{FE0E}", "🇮🇹", "🇮", "🇹",
        "1\u{FE0F}\u{20E3}", "\u{200B}", "é", "ß", "©", "\t", "\r", "\n", "\r\n",
        "\u{1B}[31m", "\u{1B}[0m", "\u{1B}[m", "\u{1B}[1;32m", "\u{1B}[48;5;17m",
        "\u{1B}[K", "\u{1B}[0K", "\u{1B}[2K", "\u{1B}[H", "\u{1B}[3C",
        "\u{1B}]8;;https://example.com\u{1B}\\", "\u{1B}]8;;\u{1B}\\", "\u{1B}]8;;https://x.y\u{07}",
        "\u{1B}]0;title\u{07}", "\u{1B}(B", "\u{1B}", "\u{7F}", "\u{01}",
    ]
    private static let columnChoices = [1, 2, 3, 4, 5, 7, 10, 16, 33, 80]
    private static let footer = "\u{1B}[23;1H\u{1B}[2KPROMPT| 界🙂\u{1B}[24;1H\u{1B}[2KSTATUS| ready"
    private static let otherFooter = "\u{1B}[22;1H\u{1B}[2KPROMPT| draft\u{1B}[23;1H\u{1B}[2KMODE| plan\u{1B}[24;1H\u{1B}[2KSTATUS| busy"

    /// The stream of `seed`: chunks, interleaved resizes and footer commits.
    private static func output(seed: UInt64) -> String {
        let writes = Mutex<[String]>([])
        let screen = TerminalPrimaryScreen(
            reports: TerminalCursorReport(), resizeGeneration: { 0 },
            output: { text in writes.withLock { $0.append(text) } }
        )
        var random = SplitMix64(state: seed)
        var geometry = TerminalPrimaryScreen.Geometry(rows: 24, columns: random.element(columnChoices))
        screen.commitFooter(geometry: geometry, reservedRows: 2, sequence: footer)
        var text = ""
        for _ in 0..<700 {
            switch random.below(10) {
            case 0: text += String(repeating: "w", count: 1 + random.below(40))
            case 1: text += String(repeating: "中", count: 1 + random.below(12))
            default: text += random.element(fragments)
            }
        }
        // Every split is drawn before the first chunk is written.
        let scalars = Array(text.unicodeScalars)
        var chunks: [String] = []
        var start = 0
        while start < scalars.count {
            let end = min(scalars.count, start + 1 + random.below(12))
            chunks.append(String(String.UnicodeScalarView(scalars[start..<end])))
            start = end
        }
        for chunk in chunks {
            let action = random.below(12)
            if action == 0 {
                geometry = .init(rows: random.element([6, 24]), columns: random.element(columnChoices))
                screen.resizeStandalone(geometry)
            } else if action == 1 {
                screen.commitFooter(geometry: geometry, reservedRows: 2, sequence: footer)
            }
            screen.append(chunk)
        }
        return writes.withLock { $0.joined() }
    }

    /// Menus and dialogs kept open across modal updates, stacking, footer
    /// commits and resizes, with writes after every change. It stays
    /// synchronous: a changed geometry is committed only once the screen is
    /// standalone, so no cursor position report is ever requested.
    private static func modalOutput(seed: UInt64) -> String {
        let writes = Mutex<[String]>([])
        let screen = TerminalPrimaryScreen(
            reports: TerminalCursorReport(), resizeGeneration: { 0 },
            output: { text in writes.withLock { $0.append(text) } }
        )
        var random = SplitMix64(state: seed)
        func write(_ count: Int = 3) {
            for _ in 0..<count {
                var chunk = ""
                for _ in 0..<(1 + random.below(8)) { chunk += random.element(fragments) }
                screen.append(chunk)
            }
        }
        func items(_ count: Int) -> [TerminalCheckboxMenu.RenderedMenuLine] {
            (0..<count).map { .init(text: "\($0 == 0 ? "›" : " ") [ ] item \($0) 界🙂", itemIndex: $0) }
        }
        let geometry = TerminalPrimaryScreen.Geometry(rows: 24, columns: 60)
        screen.commitFooter(geometry: geometry, reservedRows: 2, sequence: footer)
        write()

        // One menu, unchanged across writes, then each kind of update.
        let first = screen.beginModal()
        write()
        var menu = TerminalPrimaryScreen.Modal(
            title: "\u{1B}[1mMODELS\u{1B}[0m", help: ["↑/↓ move · Enter select", "Esc cancel"],
            lines: items(5) + [.init(text: String(repeating: "long 中 ", count: 20), itemIndex: 5)],
            focusedIndex: 1
        )
        screen.updateModal(first, value: menu); write(6)
        screen.updateModal(first, value: menu); write()
        menu.lines[2] = .init(text: "  [x] renamed 2", itemIndex: 2)
        screen.updateModal(first, value: menu); write()
        menu.focusedIndex = 4
        screen.updateModal(first, value: menu); write()
        menu.lines = items(30); menu.focusedIndex = 20
        screen.updateModal(first, value: menu); write()
        menu.focusedIndex = 3
        screen.updateModal(first, value: menu); write()
        menu.lines = items(3)
        screen.updateModal(first, value: menu); write()

        // Text input with a cursor, then a header taller than its share.
        var input = TerminalPrimaryScreen.Modal(
            title: "RENAME", help: ["Enter confirm · Esc cancel"],
            lines: [.init(text: "Name: ", itemIndex: 0)], focusedIndex: 0,
            input: String(repeating: "draft 界 value ", count: 9), inputCursor: 17
        )
        screen.updateModal(first, value: input); write()
        input.inputCursor = 90
        screen.updateModal(first, value: input); write()
        input.inputCursor = nil
        screen.updateModal(first, value: input); write()
        var table = TerminalPrimaryScreen.Modal(
            title: "BINDINGS", help: ["↑/↓ move · Tab table"], lines: items(14), focusedIndex: 0,
            header: (0..<30).map { "HEADER_\($0) │ value" }, headerScrollOffset: 7
        )
        screen.updateModal(first, value: table); write()
        table.headerScrollOffset = 12; table.headerFocused = true
        screen.updateModal(first, value: table); write()

        // The same modal becomes a dialog.
        let card = (0..<6).map { "│ consent line \($0) 🙂" }.joined(separator: "\n")
        screen.updateDialog(first, value: TerminalDialogPresentation(prompt: "\n" + card + "\n")); write()
        screen.updateDialog(first, value: TerminalDialogPresentation(prompt: card + "\n│ [y] allow  [n] deny")); write()

        // Stacked modals: the top one is drawn until it ends.
        let second = screen.beginModal()
        write()
        screen.updateModal(second, value: menu); write()
        screen.endModal(second); write()
        screen.endModal(first); write()

        // Canonically equal but byte-distinct titles: each must be drawn with
        // its own bytes, also when the top one ends.
        let composed = screen.beginModal()
        screen.updateModal(composed, value: .init(title: "caf\u{E9}", help: [], lines: items(2), focusedIndex: 0)); write()
        let decomposed = screen.beginModal()
        screen.updateModal(decomposed, value: .init(title: "cafe\u{301}", help: [], lines: items(2), focusedIndex: 0)); write()
        screen.endModal(decomposed); write()
        screen.endModal(composed); write()

        // Footer commits and resizes under an open menu, then a dialog.
        let third = screen.beginModal()
        screen.updateModal(third, value: table); write()
        screen.commitFooter(geometry: geometry, reservedRows: 3, sequence: footer); write()
        screen.commitFooter(geometry: geometry, reservedRows: 3, sequence: otherFooter); write()
        screen.resizeStandalone(.init(rows: 20, columns: 44)); write()
        screen.commitFooter(geometry: .init(rows: 30, columns: 80), reservedRows: 2, sequence: footer); write()
        screen.commitFooter(geometry: .init(rows: 30, columns: 33), reservedRows: 2, sequence: footer); write()
        screen.commitFooter(geometry: .init(rows: 12, columns: 33), reservedRows: 2, sequence: footer); write()
        screen.updateDialog(third, value: TerminalDialogPresentation(prompt: card + "\n" + card)); write()
        screen.resizeStandalone(.init(rows: 8, columns: 20)); write()
        screen.commitFooter(geometry: .init(rows: 8, columns: 20), reservedRows: 1, sequence: otherFooter); write()
        screen.endModal(third); write()
        return writes.withLock { $0.joined() }
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

/// Deterministic SplitMix64, so the streams are reproducible everywhere.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    mutating func element<T>(_ values: [T]) -> T { values[below(values.count)] }
}
