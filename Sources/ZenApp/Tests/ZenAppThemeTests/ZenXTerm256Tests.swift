import SwiftUI
import Testing

@testable import ZenAppTheme

@Suite("ZenXTerm256")
struct ZenXTerm256Tests {
    private func bytes(_ index: Int) -> [Int] {
        let value = ZenXTerm256.rgb(index)
        return [value.red, value.green, value.blue].map { Int(($0 * 255).rounded()) }
    }

    @Test("system colors 0, 8 and 15")
    func systemColors() {
        #expect(bytes(0) == [0x00, 0x00, 0x00])
        #expect(bytes(8) == [0x7F, 0x7F, 0x7F])
        #expect(bytes(15) == [0xFF, 0xFF, 0xFF])
    }

    @Test("the remaining standard colors")
    func standardColors() {
        #expect(bytes(1) == [0xCD, 0x00, 0x00])
        #expect(bytes(2) == [0x00, 0xCD, 0x00])
        #expect(bytes(3) == [0xCD, 0xCD, 0x00])
        #expect(bytes(7) == [0xE5, 0xE5, 0xE5])
        #expect(bytes(12) == [0x5C, 0x5C, 0xFF])
    }

    @Test("color cube indices 16, 81, 208 and 231")
    func colorCube() {
        #expect(bytes(16) == [0, 0, 0])
        #expect(bytes(81) == [0x5F, 0xD7, 0xFF])
        #expect(bytes(208) == [0xFF, 0x87, 0x00])
        #expect(bytes(231) == [255, 255, 255])
    }

    @Test("grayscale ramp indices 232 and 255")
    func grayscale() {
        #expect(bytes(232) == [8, 8, 8])
        #expect(bytes(255) == [238, 238, 238])
    }

    @Test("out-of-range indices clamp to 0...255")
    func clamping() {
        #expect(bytes(-1) == bytes(0))
        #expect(bytes(-100) == bytes(0))
        #expect(bytes(256) == bytes(255))
        #expect(bytes(10_000) == bytes(255))
        #expect(ZenXTerm256.color(-5) == ZenXTerm256.color(0))
        #expect(ZenXTerm256.color(300) == ZenXTerm256.color(255))
    }

    @Test("components are normalized to 0...1")
    func normalizedComponents() {
        for index in 0...255 {
            let value = ZenXTerm256.rgb(index)
            #expect((0.0...1.0).contains(value.red))
            #expect((0.0...1.0).contains(value.green))
            #expect((0.0...1.0).contains(value.blue))
        }
    }

    @Test("color(_:opacity:) and the 24-bit initializer agree with rgb")
    func colorConstruction() {
        #expect(ZenXTerm256.color(208) == Color(.sRGB, red: 1, green: 135.0 / 255, blue: 0, opacity: 1))
        #expect(ZenXTerm256.color(208, opacity: 0.5) != ZenXTerm256.color(208))
        #expect(ZenXTerm256.color(red: 0xFF, green: 0x87, blue: 0x00) == ZenXTerm256.color(208))
        #expect(ZenXTerm256.color(red: 300, green: -4, blue: 0) == ZenXTerm256.color(red: 255, green: 0, blue: 0))
    }
}

@Suite("ZenPalette")
struct ZenPaletteTests {
    @Test("dark and light palettes differ")
    func darkDiffersFromLight() {
        #expect(ZenPalette.dark != ZenPalette.light)
    }

    @Test("dark values follow TerminalStyle")
    func darkValues() {
        let dark = ZenPalette.dark
        #expect(dark.textPrimary == ZenXTerm256.color(15))
        #expect(dark.accent == ZenXTerm256.color(208))
        #expect(dark.promptBorder == ZenXTerm256.color(208, opacity: 0.5))
        #expect(dark.permissionBorder == ZenXTerm256.color(81, opacity: 0.5))
        #expect(dark.diffAdditionBackground == ZenXTerm256.color(red: 30, green: 48, blue: 36))
        #expect(dark.diffRemovalBackground == ZenXTerm256.color(red: 55, green: 32, blue: 35))
        #expect(dark.headings == [81, 75, 111, 111, 110, 109].map { ZenXTerm256.color($0) })
    }

    @Test("light values follow the light TerminalStyle palettes")
    func lightValues() {
        let light = ZenPalette.light
        #expect(light.textPrimary == ZenXTerm256.color(235))
        #expect(light.filePath == light.textPrimary)
        #expect(light.surface == ZenXTerm256.color(254))
        #expect(light.chatBorder == ZenXTerm256.color(59))
        #expect(light.diffAdditionBackground == ZenXTerm256.color(194))
        #expect(light.diffRemovalBackground == ZenXTerm256.color(224))
        #expect(light.headings == [25, 31, 61, 61, 60, 59].map { ZenXTerm256.color($0) })
        // Unlisted colors are shared with the dark palette.
        #expect(light.accent == ZenPalette.dark.accent)
        #expect(light.promptBorder == ZenPalette.dark.promptBorder)
    }

    @Test("the color scheme selects the palette")
    func colorSchemeSelection() {
        #expect(ZenPalette.forColorScheme(.dark) == ZenPalette.dark)
        #expect(ZenPalette.forColorScheme(.light) == ZenPalette.light)
    }

    @Test("the environment value follows the color scheme")
    func environmentValue() {
        var values = EnvironmentValues()
        values.colorScheme = .light
        #expect(values.zenPalette == ZenPalette.light)
        values.colorScheme = .dark
        #expect(values.zenPalette == ZenPalette.dark)
    }
}
