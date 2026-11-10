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
