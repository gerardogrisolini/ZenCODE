//
//  ZenFonts.swift
//  ZenApp
//
//  Shared fonts of the ZenCODE app.
//

import Foundation
import SwiftUI

/// Fonts shared by the monospaced parts of the app (code, tool output).
public enum ZenFonts {
    public static let mono: Font = .system(.body, design: .monospaced)
    public static let monoSmall: Font = .system(.callout, design: .monospaced)
}
