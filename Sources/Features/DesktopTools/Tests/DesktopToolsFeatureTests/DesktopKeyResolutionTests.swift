import CoreGraphics
import Foundation
import Testing
@testable import desktop_tools_feature

private struct FakeTranslator: DesktopKeyTranslating {
    let table: [CGKeyCode: [DesktopKeyLayer: String]]
    var deadKeys: Set<CGKeyCode> = []

    func character(forKeyCode keyCode: CGKeyCode, layer: DesktopKeyLayer) -> String? {
        table[keyCode]?[layer]
    }

    func isDeadKey(keyCode: CGKeyCode, layer: DesktopKeyLayer) -> Bool {
        deadKeys.contains(keyCode)
    }

    static let azerty = FakeTranslator(table: [
        12: [.none: "a"],
        0: [.none: "q"],
        13: [.none: "z"],
        6: [.none: "w"],
        18: [.none: "&", .shift: "1"],
        19: [.none: "é", .shift: "2"],
        83: [.none: "1"],
        42: [.option: "@"],
        36: [.none: "x"]
    ])
}

@Suite
struct DesktopKeyResolutionTests {
    private func resolve(_ key: String, _ translator: (any DesktopKeyTranslating)? = FakeTranslator.azerty) throws -> (CGKeyCode, CGEventFlags) {
        let result = try DesktopKeyResolver.resolve(key, translator: translator)
        return (result.keyCode, result.flags)
    }

    @Test
    func charactersUseTheLayout() throws {
        #expect(try resolve("a") == (12, []))
        #expect(try resolve("A") == (12, []))
        #expect(try resolve("q") == (0, []))
        #expect(try resolve("1") == (18, .maskShift))
        #expect(try resolve("&") == (18, []))
        #expect(try resolve("é") == (19, []))
        #expect(try resolve("@") == (42, .maskAlternate))
    }

    @Test
    func namedKeysAreLayoutIndependent() throws {
        #expect(try resolve("return") == (36, []))
        #expect(try resolve("enter") == (36, []))
        #expect(try resolve("f5") == (96, []))
        #expect(try resolve("keypad_1") == (83, []))
    }

    @Test
    func unresolvableKeysThrow() {
        #expect(throws: (any Error).self) { try resolve("ß") }
        #expect(throws: (any Error).self) { try resolve("foo") }
    }

    @Test
    func fallbackWithoutTranslatorUsesUSLayout() throws {
        #expect(try resolve("a", nil) == (0, []))
        #expect(try resolve("/", nil) == (44, []))
        #expect(throws: (any Error).self) { try resolve("€", nil) }
    }

    @Test
    func typingMapIsCaseSensitiveAndLayerOrdered() throws {
        let translator = FakeTranslator(
            table: [
                12: [.none: "a", .shift: "A"],
                18: [.none: "&", .shift: "1"],
                83: [.none: "1"],
                42: [.option: "@"],
                33: [.none: "^"],
                30: [.shift: "^"]
            ],
            deadKeys: [33]
        )
        let map = DesktopKeyResolver.typingKeyMap(translator: translator)
        func key(_ character: Character) -> (CGKeyCode, CGEventFlags)? {
            DesktopKeyResolver.typingKey(for: character, keyMap: map).map { ($0.keyCode, $0.flags) }
        }
        #expect(try #require(key("a")) == (12, []))
        #expect(try #require(key("A")) == (12, .maskShift))
        #expect(try #require(key("1")) == (18, .maskShift))
        #expect(try #require(key("@")) == (42, .maskAlternate))
        // Dead keys are skipped in favour of a key that types the character.
        #expect(try #require(key("^")) == (30, .maskShift))
        #expect(key("€") == nil)
        #expect(key("é") == nil)
    }

    @Test
    func typingKeysForWhitespaceAreLayoutIndependent() throws {
        func key(_ character: Character) -> (CGKeyCode, CGEventFlags)? {
            DesktopKeyResolver.typingKey(for: character, keyMap: [:]).map { ($0.keyCode, $0.flags) }
        }
        #expect(try #require(key("\n")) == (36, []))
        #expect(try #require(key("\r")) == (36, []))
        #expect(try #require(key("\r\n")) == (36, []))
        #expect(try #require(key("\t")) == (48, []))
        #expect(try #require(key(" ")) == (49, []))
        #expect(key("a") == nil)
    }

    @MainActor
    @Test
    func carbonTranslatorSmoke() throws {
        let translator = CarbonKeyTranslator()
        let result = try DesktopKeyResolver.resolve("return", translator: translator)
        #expect(result.keyCode == 36)
        #expect(result.flags == [])
    }
}
