//
//  BrowserKeyStroke.swift
//  BrowserToolsFeature
//
//  Keyboard key resolution for browser.act: platform, modifiers and key
//  strokes with their CDP key codes.
//

import FeatureKit
import ToolCore
import Foundation
import Synchronization

// MARK: - Key input

enum BrowserKeyPlatform: Sendable {
    case macOS
    case other

    static var current: BrowserKeyPlatform {
        #if os(macOS)
        .macOS
        #else
        .other
        #endif
    }
}

struct BrowserKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    // CDP Input.dispatchKeyEvent modifier bits.
    static let alt = BrowserKeyModifiers(rawValue: 1)
    static let control = BrowserKeyModifiers(rawValue: 2)
    static let meta = BrowserKeyModifiers(rawValue: 4)
    static let shift = BrowserKeyModifiers(rawValue: 8)

    static func named(_ rawValue: String) -> BrowserKeyModifiers? {
        switch rawValue.lowercased() {
        case "ctrl", "control": .control
        case "meta", "cmd", "command": .meta
        case "alt", "option", "opt": .alt
        case "shift": .shift
        default: nil
        }
    }
}

struct BrowserKeyStroke: Equatable, Sendable {
    let key: String
    let code: String
    let virtualKeyCode: Int
    let modifiers: BrowserKeyModifiers
    /// Text the key produces; nil for keys that only trigger behavior.
    let text: String?
    /// Chrome editor commands that must accompany the key event.
    let commands: [String]

    init(
        key: String,
        code: String,
        virtualKeyCode: Int,
        modifiers: BrowserKeyModifiers = [],
        text: String? = nil,
        commands: [String] = []
    ) {
        self.key = key
        self.code = code
        self.virtualKeyCode = virtualKeyCode
        self.modifiers = modifiers
        self.text = text
        self.commands = commands
    }

    private static let namedKeys: [String: BrowserKeyStroke] = [
        "enter": .init(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\r"),
        "tab": .init(key: "Tab", code: "Tab", virtualKeyCode: 9),
        "escape": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
        "esc": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
        "space": .init(key: " ", code: "Space", virtualKeyCode: 32, text: " "),
        "backspace": .init(key: "Backspace", code: "Backspace", virtualKeyCode: 8),
        "delete": .init(key: "Delete", code: "Delete", virtualKeyCode: 46),
        "arrowup": .init(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38),
        "arrowdown": .init(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40),
        "arrowleft": .init(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37),
        "arrowright": .init(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39),
        "home": .init(key: "Home", code: "Home", virtualKeyCode: 36),
        "end": .init(key: "End", code: "End", virtualKeyCode: 35),
        "pageup": .init(key: "PageUp", code: "PageUp", virtualKeyCode: 33),
        "pagedown": .init(key: "PageDown", code: "PageDown", virtualKeyCode: 34),
    ]

    /// macOS editing shortcuts. Chrome performs them only when the editor
    /// command travels with the synthetic key event.
    private static let macOSCommandShortcuts: [String: String] = [
        "a": "selectAll",
        "c": "copy",
        "x": "cut",
        "v": "paste",
        "z": "undo",
    ]

    /// Resolves `Key` or a `Modifier+...+Key` combination such as
    /// `Control+A`, `Meta+Enter`, or `Shift+Tab`. A bare letter or digit is
    /// rejected: text entry belongs to `fill`, and only a Control, Meta, or
    /// Alt modifier turns a character into a shortcut.
    static func resolve(_ rawValue: String?, platform: BrowserKeyPlatform = .current) throws -> BrowserKeyStroke {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("key")
        }
        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let baseName = parts.last, parts.allSatisfy({ !$0.isEmpty }) else {
            throw BrowserInteractionError.unsupportedKey(rawValue)
        }
        var modifiers: BrowserKeyModifiers = []
        for name in parts.dropLast() {
            guard let modifier = BrowserKeyModifiers.named(name), !modifiers.contains(modifier) else {
                throw BrowserInteractionError.unsupportedKey(rawValue)
            }
            modifiers.insert(modifier)
        }
        let producesText = modifiers.isSubset(of: [.shift])

        let normalized = baseName
            .lowercased()
            .filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
        if let named = namedKeys[normalized] {
            return BrowserKeyStroke(
                key: named.key,
                code: named.code,
                virtualKeyCode: named.virtualKeyCode,
                modifiers: modifiers,
                text: producesText ? named.text : nil
            )
        }

        guard baseName.count == 1,
              let character = baseName.lowercased().first,
              character.isASCII,
              character.isLetter || character.isNumber,
              !modifiers.isDisjoint(with: [.control, .meta, .alt])
        else {
            throw BrowserInteractionError.unsupportedKey(rawValue)
        }
        let upper = String(character).uppercased()
        let virtualKeyCode = Int(upper.unicodeScalars.first?.value ?? 0)
        var commands: [String] = []
        if platform == .macOS, modifiers.contains(.meta), modifiers.isSubset(of: [.meta, .shift]) {
            if character == "z", modifiers.contains(.shift) {
                commands = ["redo"]
            } else if !modifiers.contains(.shift), let command = macOSCommandShortcuts[String(character)] {
                commands = [command]
            }
        }
        return BrowserKeyStroke(
            key: modifiers.contains(.shift) ? upper : String(character),
            code: character.isLetter ? "Key\(upper)" : "Digit\(character)",
            virtualKeyCode: virtualKeyCode,
            modifiers: modifiers,
            commands: commands
        )
    }

    /// The platform's select-all shortcut, used before replacing editor text.
    static func selectAll(platform: BrowserKeyPlatform = .current) -> BrowserKeyStroke {
        // `try!` is safe: the literal is a supported combination.
        try! resolve(platform == .macOS ? "Meta+A" : "Control+A", platform: platform)
    }

    /// A soft line break. Shift+Enter inserts a newline in rich-text editors
    /// without triggering the "send on Enter" behavior of chat composers.
    static let softLineBreak = BrowserKeyStroke(
        key: "Enter",
        code: "Enter",
        virtualKeyCode: 13,
        modifiers: .shift,
        text: "\r"
    )

    static let backspace = BrowserKeyStroke(key: "Backspace", code: "Backspace", virtualKeyCode: 8)
}
