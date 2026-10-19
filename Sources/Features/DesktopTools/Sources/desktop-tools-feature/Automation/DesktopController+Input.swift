//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import CoreGraphics
import Foundation
import ToolCore

extension DesktopController {

    struct MouseButtonDefinition {
        let name: String
        let button: CGMouseButton
        let down: CGEventType
        let dragged: CGEventType
        let up: CGEventType
    }

    struct ScrollUnitDefinition {
        let name: String
        let unit: CGScrollEventUnit
    }

    static func parseMouseButton(_ value: String?) throws -> MouseButtonDefinition {
        switch (value?.nilIfBlank ?? "left").lowercased() {
        case "left": return MouseButtonDefinition(name: "left", button: .left, down: .leftMouseDown, dragged: .leftMouseDragged, up: .leftMouseUp)
        case "right": return MouseButtonDefinition(name: "right", button: .right, down: .rightMouseDown, dragged: .rightMouseDragged, up: .rightMouseUp)
        case "middle": return MouseButtonDefinition(name: "middle", button: .center, down: .otherMouseDown, dragged: .otherMouseDragged, up: .otherMouseUp)
        default: throw DesktopControlError.invalidArgument("button", "must be left, right, or middle.")
        }
    }

    static func parseScrollUnit(_ value: String?) throws -> ScrollUnitDefinition {
        switch (value?.nilIfBlank ?? "pixel").lowercased() {
        case "pixel": return ScrollUnitDefinition(name: "pixel", unit: .pixel)
        case "line": return ScrollUnitDefinition(name: "line", unit: .line)
        default: throw DesktopControlError.invalidArgument("scroll_unit", "must be pixel or line.")
        }
    }

    static func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw DesktopControlError.operationFailed("Could not create a Quartz HID event source.")
        }
        return source
    }

    static func pointerSteps(_ duration: Double) -> Int {
        duration == 0 ? 1 : min(max(Int((duration * 60).rounded()), 1), 240)
    }

    static func interpolate(_ start: CGPoint, _ end: CGPoint, step: Int, of steps: Int) -> CGPoint {
        let progress = CGFloat(step) / CGFloat(steps)
        return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }

    static func movePointer(to destination: CGPoint, duration: Double) throws {
        let source = try eventSource()
        let start = currentPointerLocation()
        let steps = pointerSteps(duration)
        for step in 1...steps {
            let point = interpolate(start, destination, step: step, of: steps)
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                throw DesktopControlError.operationFailed("Could not create a mouse movement event.")
            }
            event.post(tap: .cghidEventTap)
            if duration > 0 { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }
    }

    static func click(button: MouseButtonDefinition, count: Int) throws {
        let source = try eventSource()
        let location = currentPointerLocation()
        for clickIndex in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: button.down, mouseCursorPosition: location, mouseButton: button.button),
                  let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: location, mouseButton: button.button) else {
                throw DesktopControlError.operationFailed("Could not create mouse click events.")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            if clickIndex < count { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    static func dragPointer(from start: CGPoint, to destination: CGPoint, duration: Double, button: MouseButtonDefinition) throws {
        try movePointer(to: start, duration: 0)
        let source = try eventSource()
        guard let down = CGEvent(mouseEventSource: source, mouseType: button.down, mouseCursorPosition: start, mouseButton: button.button) else {
            throw DesktopControlError.operationFailed("Could not create the drag mouse-down event.")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)

        let steps = pointerSteps(duration)
        for step in 1...steps {
            let point = interpolate(start, destination, step: step, of: steps)
            guard let event = CGEvent(mouseEventSource: source, mouseType: button.dragged, mouseCursorPosition: point, mouseButton: button.button) else {
                if let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: point, mouseButton: button.button) {
                    up.post(tap: .cghidEventTap)
                }
                throw DesktopControlError.operationFailed("Could not create a drag movement event.")
            }
            event.post(tap: .cghidEventTap)
            if duration > 0 { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: destination, mouseButton: button.button) else {
            throw DesktopControlError.operationFailed("Could not create the drag mouse-up event.")
        }
        up.post(tap: .cghidEventTap)
    }

    static func postScroll(deltaX: Int32, deltaY: Int32, unit: ScrollUnitDefinition) throws {
        let source = try eventSource()
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: unit.unit,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw DesktopControlError.operationFailed("Could not create a scroll event.")
        }
        event.post(tap: .cghidEventTap)
    }

    static func typeText(_ text: String, interval: Double) throws {
        try Task.checkCancellation()
        let source = try eventSource()
        for character in text {
            try Task.checkCancellation()
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw DesktopControlError.operationFailed("Could not create Unicode keyboard events.")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
    }

    static func pressKey(_ name: String, modifiers: CGEventFlags, repeatCount: Int, interval: Double) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keyCode = keyCodes[normalized] else {
            throw DesktopControlError.invalidArgument(
                "key",
                "unsupported key '\(name)'. Use type_text for arbitrary text; common letters, digits, punctuation, arrows, navigation keys, return/tab/escape/delete, and F1-F20 are supported."
            )
        }
        let source = try eventSource()
        for index in 0..<repeatCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw DesktopControlError.operationFailed("Could not create keyboard events.")
            }
            down.flags = modifiers
            up.flags = modifiers
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            if index + 1 < repeatCount, interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
    }

    static func modifierFlags(_ values: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for value in values {
            switch value.lowercased() {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw DesktopControlError.invalidArgument("modifiers", "unsupported modifier '\(value)'.")
            }
        }
        return flags
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f17": 64, "keypad_decimal": 65, "keypad_multiply": 67, "keypad_plus": 69, "keypad_clear": 71,
        "volume_up": 72, "volume_down": 73, "mute": 74, "keypad_divide": 75, "keypad_enter": 76,
        "keypad_minus": 78, "f18": 79, "f19": 80, "keypad_equals": 81, "keypad_0": 82,
        "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87,
        "keypad_6": 88, "keypad_7": 89, "f20": 90, "keypad_8": 91, "keypad_9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "help": 114, "home": 115, "page_up": 116, "forward_delete": 117, "f4": 118, "end": 119,
        "f2": 120, "page_down": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

}
