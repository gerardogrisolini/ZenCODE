//
//  FigmaFormat.swift
//  ZenCODE
//
//  Value formatting shared by the Figma renderers: numbers, colors, paints,
//  effects, typography, and bounded text output.
//

import Foundation
import ToolCore

enum FigmaLimits {
    /// Character budget of one rendered tool output.
    static let outputCharacters = 80_000
    /// Longest text-layer content quoted verbatim.
    static let textCharacters = 2_000
}

struct FigmaBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init?(node: JSONValue) {
        guard let box = node["absoluteBoundingBox"],
              let x = box["x"]?.numberValue,
              let y = box["y"]?.numberValue,
              let width = box["width"]?.numberValue,
              let height = box["height"]?.numberValue else {
            return nil
        }
        self.init(x: x, y: y, width: width, height: height)
    }

    /// Position relative to `parent`, or absolute canvas coordinates without one.
    func origin(relativeTo parent: FigmaBox?) -> (x: Double, y: Double) {
        guard let parent else { return (x, y) }
        return (x - parent.x, y - parent.y)
    }
}

/// Line accumulator that stops at a character budget and remembers how many
/// nodes it had to leave out.
struct FigmaTextBudget {
    let limit: Int
    private(set) var lines: [String] = []
    private(set) var characterCount = 0
    private(set) var isExhausted = false
    var omittedNodeCount = 0

    init(limit: Int = FigmaLimits.outputCharacters) {
        self.limit = limit
    }

    @discardableResult
    mutating func append(_ line: String) -> Bool {
        guard !isExhausted else { return false }
        let cost = line.count + 1
        guard characterCount + cost <= limit else {
            isExhausted = true
            return false
        }
        lines.append(line)
        characterCount += cost
        return true
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}

enum FigmaFormat {
    static let vectorTypes: Set<String> = [
        "VECTOR", "BOOLEAN_OPERATION", "STAR", "LINE", "ELLIPSE", "REGULAR_POLYGON"
    ]

    /// Up to two decimals, without trailing zeros (`12`, `0.5`, `-3.25`).
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the effective alpha is below 1.
    static func hex(_ color: JSONValue?, opacity: Double = 1) -> String? {
        guard let color,
              let red = color["r"]?.numberValue,
              let green = color["g"]?.numberValue,
              let blue = color["b"]?.numberValue else {
            return nil
        }
        let alpha = (color["a"]?.numberValue ?? 1) * opacity
        func byte(_ component: Double) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        var text = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        if byte(alpha) < 255 {
            text += String(format: "%02X", byte(alpha))
        }
        return text
    }

    /// Describes one visible paint; `nil` for hidden paints.
    static func paint(_ paint: JSONValue) -> String? {
        guard paint["visible"]?.boolValue != false else { return nil }
        let opacity = paint["opacity"]?.numberValue ?? 1
        let type = paint["type"]?.stringValue ?? "UNKNOWN"
        var text: String
        switch type {
        case "SOLID":
            text = hex(paint["color"], opacity: opacity) ?? "solid"
        case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
            let stops = (paint["gradientStops"]?.arrayValue ?? []).compactMap { stop -> String? in
                guard let color = hex(stop["color"], opacity: opacity) else { return nil }
                return "\(color) \(number((stop["position"]?.numberValue ?? 0) * 100))%"
            }
            let kind = type.dropFirst("GRADIENT_".count).lowercased()
            text = "\(kind)-gradient(\(stops.joined(separator: ", ")))"
        case "IMAGE":
            text = "image(\(paint["scaleMode"]?.stringValue?.lowercased() ?? "fill"))"
            if let reference = paint["imageRef"]?.stringValue?.nilIfBlank {
                text += " ref \(reference)"
            }
            if opacity < 1 {
                text += " opacity \(number(opacity))"
            }
        default:
            text = type.lowercased()
        }
        if let blendMode = paint["blendMode"]?.stringValue, blendMode != "NORMAL", blendMode != "PASS_THROUGH" {
            text += " blend \(blendMode.lowercased())"
        }
        return text
    }

    static func paints(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap(paint)
    }

    /// Describes one visible effect; `nil` for hidden effects.
    static func effect(_ effect: JSONValue) -> String? {
        guard effect["visible"]?.boolValue != false else { return nil }
        let type = effect["type"]?.stringValue ?? "EFFECT"
        let radius = number(effect["radius"]?.numberValue ?? 0)
        switch type {
        case "DROP_SHADOW", "INNER_SHADOW":
            let name = type == "DROP_SHADOW" ? "drop-shadow" : "inner-shadow"
            let x = number(effect["offset"]?["x"]?.numberValue ?? 0)
            let y = number(effect["offset"]?["y"]?.numberValue ?? 0)
            let spread = number(effect["spread"]?.numberValue ?? 0)
            let color = hex(effect["color"]) ?? "#000000"
            return "\(name) \(color) x \(x) y \(y) blur \(radius) spread \(spread)"
        case "LAYER_BLUR":
            return "layer-blur \(radius)"
        case "BACKGROUND_BLUR":
            return "background-blur \(radius)"
        default:
            return type.lowercased().replacingOccurrences(of: "_", with: "-")
        }
    }

    static func effects(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap(effect)
    }

    /// Compact typography summary, e.g. `Inter Semi Bold 600, 16px/24px, align center`.
    static func typeStyle(_ style: JSONValue) -> String {
        var parts: [String] = []
        var font = style["fontFamily"]?.stringValue ?? "unknown font"
        if let fontStyle = style["fontStyle"]?.stringValue?.nilIfBlank {
            font += " \(fontStyle)"
        }
        if let weight = style["fontWeight"]?.numberValue {
            font += " \(number(weight))"
        }
        parts.append(font)
        if let size = style["fontSize"]?.numberValue {
            var sizeText = "\(number(size))px"
            if let lineHeight = lineHeight(style) {
                sizeText += "/\(lineHeight)"
            }
            parts.append(sizeText)
        }
        if let letterSpacing = style["letterSpacing"]?.numberValue, letterSpacing != 0 {
            parts.append("letter-spacing \(number(letterSpacing))px")
        }
        if let align = style["textAlignHorizontal"]?.stringValue, align != "LEFT" {
            parts.append("align \(align.lowercased())")
        }
        if let align = style["textAlignVertical"]?.stringValue, align != "TOP" {
            parts.append("vertical-align \(align.lowercased())")
        }
        if let textCase = style["textCase"]?.stringValue, textCase != "ORIGINAL" {
            parts.append("case \(textCase.lowercased().replacingOccurrences(of: "_", with: "-"))")
        }
        if let decoration = style["textDecoration"]?.stringValue, decoration != "NONE" {
            parts.append(decoration.lowercased())
        }
        if style["italic"]?.boolValue == true {
            parts.append("italic")
        }
        if style["textTruncation"]?.stringValue == "ENDING" {
            var truncation = "truncate"
            if let maxLines = style["maxLines"]?.numberValue {
                truncation += " after \(number(maxLines)) lines"
            }
            parts.append(truncation)
        }
        return parts.joined(separator: ", ")
    }

    /// Style definition in the shape used by Figma's own variable tooling.
    static func fontDefinition(_ style: JSONValue) -> String {
        var fields: [String] = []
        if let family = style["fontFamily"]?.stringValue {
            fields.append("family: \"\(family)\"")
        }
        if let fontStyle = style["fontStyle"]?.stringValue?.nilIfBlank {
            fields.append("style: \(fontStyle)")
        }
        if let size = style["fontSize"]?.numberValue {
            fields.append("size: \(number(size))")
        }
        if let weight = style["fontWeight"]?.numberValue {
            fields.append("weight: \(number(weight))")
        }
        if let lineHeight = style["lineHeightPx"]?.numberValue {
            fields.append("lineHeight: \(number(lineHeight))")
        }
        fields.append("letterSpacing: \(number(style["letterSpacing"]?.numberValue ?? 0))")
        return "Font(\(fields.joined(separator: ", ")))"
    }

    private static func lineHeight(_ style: JSONValue) -> String? {
        switch style["lineHeightUnit"]?.stringValue {
        case "INTRINSIC_%":
            return "auto"
        case "FONT_SIZE_%":
            if let percent = style["lineHeightPercentFontSize"]?.numberValue {
                return "\(number(percent))%"
            }
            fallthrough
        default:
            return style["lineHeightPx"]?.numberValue.map { "\(number($0))px" }
        }
    }

    /// `FRAME` -> `frame`, `COMPONENT_SET` -> `component-set`, `CANVAS` -> `page`.
    static func tagName(forType type: String) -> String {
        type == "CANVAS" ? "page" : type.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    static func xmlEscaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n": result += "&#10;"
            default: result.append(character)
            }
        }
        return result
    }

    /// JSON-style quoted string with control characters escaped.
    static func quoted(_ value: String, limit: Int = FigmaLimits.textCharacters) -> String {
        var text = value
        var suffix = ""
        if text.count > limit {
            text = String(text.prefix(limit))
            suffix = "… (\(value.count - limit) more characters)"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let escaped = (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(text)\""
        return escaped + suffix
    }

    /// Number of nodes in a subtree, used to report what a budget left out.
    static func nodeCount(_ node: JSONValue) -> Int {
        1 + (node["children"]?.arrayValue ?? []).reduce(0) { $0 + nodeCount($1) }
    }

    /// Strips the `#123:4` suffix Figma appends to component property names.
    static func propertyName(_ raw: String) -> String {
        guard let index = raw.lastIndex(of: "#") else { return raw }
        let name = raw[..<index]
        return name.isEmpty ? raw : String(name)
    }
}
