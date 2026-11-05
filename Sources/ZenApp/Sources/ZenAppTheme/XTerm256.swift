//
//  XTerm256.swift
//  ZenApp
//
//  The xterm 256-color table, so the app can reuse the exact colors the
//  terminal UI selects with `38;5;N` and `48;5;N` sequences.
//

import Foundation
import SwiftUI

/// Converts xterm-256 palette indices (and 24-bit SGR values) to SwiftUI colors.
public enum ZenXTerm256 {
    /// Levels of the 6x6x6 color cube (indices 16...231).
    private static let cubeLevels = [0, 95, 135, 175, 215, 255]

    /// The sixteen standard and bright colors (indices 0...15), as 0xRRGGBB.
    private static let systemColors: [Int] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00,
        0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00,
        0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF
    ]

    /// Returns the 8-bit RGB components of a palette index; out-of-range
    /// indices are clamped to `0...255`.
    static func components(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        let index = min(max(index, 0), 255)
        switch index {
        case 0..<16:
            let value = systemColors[index]
            return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        case 16..<232:
            let cube = index - 16
            return (
                cubeLevels[cube / 36],
                cubeLevels[(cube / 6) % 6],
                cubeLevels[cube % 6]
            )
        default:
            let gray = 8 + 10 * (index - 232)
            return (gray, gray, gray)
        }
    }

    /// The RGB components of a palette index, each in `0...1`.
    public static func rgb(_ index: Int) -> (red: Double, green: Double, blue: Double) {
        let value = components(index)
        return (Double(value.red) / 255, Double(value.green) / 255, Double(value.blue) / 255)
    }

    /// The color of a palette index (`38;5;N` / `48;5;N`).
    public static func color(_ index: Int, opacity: Double = 1) -> Color {
        let value = rgb(index)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: opacity)
    }

    /// A 24-bit color (`38;2;r;g;b` / `48;2;r;g;b`); components clamp to `0...255`.
    public static func color(red: Int, green: Int, blue: Int) -> Color {
        func unit(_ component: Int) -> Double {
            Double(min(max(component, 0), 255)) / 255
        }
        return Color(.sRGB, red: unit(red), green: unit(green), blue: unit(blue), opacity: 1)
    }
}
