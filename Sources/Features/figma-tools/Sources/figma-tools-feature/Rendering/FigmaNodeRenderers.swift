//
//  FigmaNodeRenderers.swift
//  ZenCODE
//
//  Renders Figma REST node trees as a compact XML outline (metadata) and as
//  a readable implementation spec (design context).
//

import Foundation
import ToolCore

enum FigmaMetadataRenderer {
    /// Appends `node` and its descendants as XML. x/y are relative to the
    /// parent bounding box (absolute canvas coordinates for top-level frames).
    static func render(
        _ node: JSONValue,
        parentBox: FigmaBox?,
        indent: Int = 0,
        budget: inout FigmaTextBudget
    ) {
        guard !budget.isExhausted else {
            budget.omittedNodeCount += FigmaFormat.nodeCount(node)
            return
        }

        let type = node["type"]?.stringValue ?? "NODE"
        let tag = FigmaFormat.tagName(forType: type)
        let box = FigmaBox(node: node)
        var attributes: [String] = []
        if let id = node["id"]?.stringValue {
            attributes.append("id=\"\(FigmaFormat.xmlEscaped(id))\"")
        }
        if let name = node["name"]?.stringValue {
            attributes.append("name=\"\(FigmaFormat.xmlEscaped(name))\"")
        }
        if let box {
            let origin = box.origin(relativeTo: parentBox)
            attributes.append("x=\"\(FigmaFormat.number(origin.x))\"")
            attributes.append("y=\"\(FigmaFormat.number(origin.y))\"")
            attributes.append("width=\"\(FigmaFormat.number(box.width))\"")
            attributes.append("height=\"\(FigmaFormat.number(box.height))\"")
        }
        if node["visible"]?.boolValue == false {
            attributes.append("hidden=\"true\"")
        }

        let padding = String(repeating: "  ", count: indent)
        let opening = "\(padding)<\(tag) \(attributes.joined(separator: " "))"
        let children = node["children"]?.arrayValue ?? []
        guard !children.isEmpty else {
            if !budget.append(opening + " />") {
                budget.omittedNodeCount += 1
            }
            return
        }
        guard budget.append(opening + ">") else {
            budget.omittedNodeCount += FigmaFormat.nodeCount(node)
            return
        }
        for child in children {
            render(child, parentBox: box ?? parentBox, indent: indent + 1, budget: &budget)
        }
        budget.append("\(padding)</\(tag)>")
    }
}

enum FigmaDesignContextRenderer {
    struct Usage {
        var componentIDs: [String] = []
        var styleIDs: [String] = []
    }

    /// Renders the node tree of a `/v1/files/:key/nodes` entry and the
    /// components and styles it references.
    static func render(entry: JSONValue, budget: inout FigmaTextBudget) {
        guard let document = entry["document"] else { return }
        let components = entry["components"]?.objectValue ?? [:]
        let styles = entry["styles"]?.objectValue ?? [:]
        var usage = Usage()

        renderNode(
            document,
            parentBox: nil,
            indent: 0,
            components: components,
            styles: styles,
            usage: &usage,
            budget: &budget
        )

        if !usage.componentIDs.isEmpty {
            budget.append("")
            budget.append("Components:")
            for id in usage.componentIDs {
                let component = components[id]
                var line = "- \(component?["name"]?.stringValue ?? id) [\(id)]"
                if let key = component?["key"]?.stringValue?.nilIfBlank {
                    line += " key \(key)"
                }
                if component?["remote"]?.boolValue == true {
                    line += " (library)"
                }
                if let description = component?["description"]?.stringValue?.nilIfBlank {
                    line += ": \(description.replacingOccurrences(of: "\n", with: " "))"
                }
                budget.append(line)
            }
        }
        if !usage.styleIDs.isEmpty {
            budget.append("")
            budget.append("Styles:")
            for id in usage.styleIDs {
                let style = styles[id]
                var line = "- \(style?["name"]?.stringValue ?? id)"
                if let type = style?["styleType"]?.stringValue {
                    line += " (\(type.lowercased()))"
                }
                if let description = style?["description"]?.stringValue?.nilIfBlank {
                    line += ": \(description.replacingOccurrences(of: "\n", with: " "))"
                }
                budget.append(line)
            }
        }
    }

    private static func renderNode(
        _ node: JSONValue,
        parentBox: FigmaBox?,
        indent: Int,
        components: [String: JSONValue],
        styles: [String: JSONValue],
        usage: inout Usage,
        budget: inout FigmaTextBudget
    ) {
        guard !budget.isExhausted else {
            budget.omittedNodeCount += FigmaFormat.nodeCount(node)
            return
        }

        let type = node["type"]?.stringValue ?? "NODE"
        let box = FigmaBox(node: node)
        let padding = String(repeating: "  ", count: indent)
        let detailPadding = padding + "  "

        var header = "\(padding)- \(type) \(FigmaFormat.quoted(node["name"]?.stringValue ?? "", limit: 200))"
        if let id = node["id"]?.stringValue {
            header += " [\(id)]"
        }
        if let box {
            let origin = box.origin(relativeTo: parentBox)
            header += " \(FigmaFormat.number(box.width))x\(FigmaFormat.number(box.height))"
            header += " at (\(FigmaFormat.number(origin.x)), \(FigmaFormat.number(origin.y)))"
        }
        if node["visible"]?.boolValue == false {
            header += " hidden"
        }
        guard budget.append(header) else {
            budget.omittedNodeCount += FigmaFormat.nodeCount(node)
            return
        }

        for line in detailLines(for: node, type: type, components: components, styles: styles, usage: &usage) {
            budget.append(detailPadding + line)
        }

        let children = node["children"]?.arrayValue ?? []
        if FigmaFormat.vectorTypes.contains(type), !children.isEmpty {
            budget.append("\(detailPadding)shape: \(children.count) vector layers (export as an asset)")
            return
        }
        for child in children {
            renderNode(
                child,
                parentBox: box ?? parentBox,
                indent: indent + 1,
                components: components,
                styles: styles,
                usage: &usage,
                budget: &budget
            )
        }
    }

    static func detailLines(
        for node: JSONValue,
        type: String,
        components: [String: JSONValue],
        styles: [String: JSONValue],
        usage: inout Usage
    ) -> [String] {
        var lines: [String] = []
        let styleReferences = node["styles"]?.objectValue ?? [:]

        func styleSuffix(_ keys: [String]) -> String {
            for key in keys {
                if let id = styleReferences[key]?.stringValue {
                    if !usage.styleIDs.contains(id) { usage.styleIDs.append(id) }
                    let name = styles[id]?["name"]?.stringValue ?? id
                    return " (style \(FigmaFormat.quoted(name, limit: 200)))"
                }
            }
            return ""
        }

        if type == "INSTANCE", let componentID = node["componentId"]?.stringValue {
            if !usage.componentIDs.contains(componentID) { usage.componentIDs.append(componentID) }
            var line = "instance of \(FigmaFormat.quoted(components[componentID]?["name"]?.stringValue ?? componentID, limit: 200))"
            let properties = (node["componentProperties"]?.objectValue ?? [:])
                .sorted { $0.key < $1.key }
                .compactMap { name, property -> String? in
                    guard let value = property["value"]?.flexibleStringValue else { return nil }
                    return "\(FigmaFormat.propertyName(name))=\(value)"
                }
            if !properties.isEmpty {
                line += " with \(properties.joined(separator: ", "))"
            }
            lines.append(line)
        }
        if type == "COMPONENT" || type == "COMPONENT_SET",
           let definitions = node["componentPropertyDefinitions"]?.objectValue, !definitions.isEmpty {
            let rendered = definitions.sorted { $0.key < $1.key }.map { name, definition -> String in
                var text = "\(FigmaFormat.propertyName(name)) (\(definition["type"]?.stringValue?.lowercased() ?? "property")"
                if let options = definition["variantOptions"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
                    text += ": \(options.joined(separator: " | "))"
                } else if let defaultValue = definition["defaultValue"]?.flexibleStringValue {
                    text += ", default \(defaultValue)"
                }
                return text + ")"
            }
            lines.append("properties: \(rendered.joined(separator: "; "))")
        }

        if let layout = autoLayout(node) {
            lines.append(layout)
        }
        if let sizing = sizing(node) {
            lines.append(sizing)
        }
        if let constraints = constraints(node) {
            lines.append(constraints)
        }

        if type == "TEXT" {
            if let characters = node["characters"]?.stringValue {
                lines.append("text: \(FigmaFormat.quoted(characters))")
            }
            if let style = node["style"] {
                var line = "font: \(FigmaFormat.typeStyle(style))\(styleSuffix(["text"]))"
                let overrides = node["characterStyleOverrides"]?.arrayValue ?? []
                if overrides.contains(where: { ($0.numberValue ?? 0) != 0 }) {
                    let runs = node["styleOverrideTable"]?.objectValue?.count ?? 0
                    line += "; mixed styles (\(runs) override\(runs == 1 ? "" : "s"))"
                }
                lines.append(line)
            }
            let colors = FigmaFormat.paints(node["fills"])
            if !colors.isEmpty {
                lines.append("color: \(colors.joined(separator: ", "))\(styleSuffix(["fill", "fills"]))")
            }
        } else {
            let fills = FigmaFormat.paints(node["fills"])
            if !fills.isEmpty {
                lines.append("fill: \(fills.joined(separator: ", "))\(styleSuffix(["fill", "fills"]))")
            }
        }

        let strokes = FigmaFormat.paints(node["strokes"])
        if !strokes.isEmpty {
            var line = "stroke: \(strokes.joined(separator: ", "))"
            if let weights = node["individualStrokeWeights"],
               let top = weights["top"]?.numberValue, let right = weights["right"]?.numberValue,
               let bottom = weights["bottom"]?.numberValue, let left = weights["left"]?.numberValue {
                line += " \([top, right, bottom, left].map(FigmaFormat.number).joined(separator: " "))px"
            } else if let weight = node["strokeWeight"]?.numberValue {
                line += " \(FigmaFormat.number(weight))px"
            }
            if let align = node["strokeAlign"]?.stringValue {
                line += " \(align.lowercased())"
            }
            if let dashes = node["strokeDashes"]?.arrayValue?.compactMap(\.numberValue), !dashes.isEmpty {
                line += " dashed \(dashes.map(FigmaFormat.number).joined(separator: " "))"
            }
            lines.append(line + styleSuffix(["stroke", "strokes"]))
        }

        if let radii = node["rectangleCornerRadii"]?.arrayValue?.compactMap(\.numberValue), radii.count == 4,
           Set(radii).count > 1 {
            lines.append("radius: \(radii.map(FigmaFormat.number).joined(separator: " ")) (top-left top-right bottom-right bottom-left)")
        } else if let radius = node["cornerRadius"]?.numberValue, radius > 0 {
            lines.append("radius: \(FigmaFormat.number(radius))")
        }

        let effects = FigmaFormat.effects(node["effects"])
        if !effects.isEmpty {
            lines.append("effects: \(effects.joined(separator: "; "))\(styleSuffix(["effect", "effects"]))")
        }
        if let opacity = node["opacity"]?.numberValue, opacity < 1 {
            lines.append("opacity: \(FigmaFormat.number(opacity))")
        }
        if let blendMode = node["blendMode"]?.stringValue, blendMode != "PASS_THROUGH", blendMode != "NORMAL" {
            lines.append("blend: \(blendMode.lowercased())")
        }
        if node["clipsContent"]?.boolValue == true {
            lines.append("clips content")
        }
        if node["isMask"]?.boolValue == true {
            lines.append("mask")
        }
        if let exports = node["exportSettings"]?.arrayValue, !exports.isEmpty {
            let formats = exports.compactMap { setting -> String? in
                guard let format = setting["format"]?.stringValue else { return nil }
                if let value = setting["constraint"]?["value"]?.numberValue,
                   setting["constraint"]?["type"]?.stringValue == "SCALE", value != 1 {
                    return "\(format)@\(FigmaFormat.number(value))x"
                }
                return format
            }
            lines.append("export: \(formats.joined(separator: ", "))")
        }
        if let link = node["hyperlink"]?["url"]?.stringValue?.nilIfBlank {
            lines.append("link: \(link)")
        }
        return lines
    }

    private static func autoLayout(_ node: JSONValue) -> String? {
        guard let mode = node["layoutMode"]?.stringValue, mode != "NONE" else { return nil }
        let direction: String
        switch mode {
        case "HORIZONTAL": direction = "row"
        case "VERTICAL": direction = "column"
        default: direction = mode.lowercased()
        }
        func alignment(_ value: String?) -> String {
            switch value {
            case "MAX": return "end"
            case "CENTER": return "center"
            case "SPACE_BETWEEN": return "space-between"
            case "BASELINE": return "baseline"
            default: return "start"
            }
        }
        func value(_ key: String) -> String {
            FigmaFormat.number(node[key]?.numberValue ?? 0)
        }
        var parts = ["auto-layout: \(direction)"]
        if node["primaryAxisAlignItems"]?.stringValue != "SPACE_BETWEEN" {
            parts.append("gap \(value("itemSpacing"))")
        }
        if node["layoutWrap"]?.stringValue == "WRAP" {
            parts.append("wrap, row-gap \(value("counterAxisSpacing"))")
        }
        parts.append("padding \(value("paddingTop")) \(value("paddingRight")) \(value("paddingBottom")) \(value("paddingLeft"))")
        parts.append("main-axis \(alignment(node["primaryAxisAlignItems"]?.stringValue))")
        parts.append("cross-axis \(alignment(node["counterAxisAlignItems"]?.stringValue))")
        if node["itemReverseZIndex"]?.boolValue == true {
            parts.append("reverse z-order")
        }
        return parts.joined(separator: ", ")
    }

    private static func sizing(_ node: JSONValue) -> String? {
        var parts: [String] = []
        if let horizontal = node["layoutSizingHorizontal"]?.stringValue {
            parts.append("width \(horizontal.lowercased())")
        }
        if let vertical = node["layoutSizingVertical"]?.stringValue {
            parts.append("height \(vertical.lowercased())")
        }
        if let grow = node["layoutGrow"]?.numberValue, grow > 0 {
            parts.append("grow \(FigmaFormat.number(grow))")
        }
        for key in ["minWidth", "maxWidth", "minHeight", "maxHeight"] {
            if let value = node[key]?.numberValue {
                parts.append("\(key) \(FigmaFormat.number(value))")
            }
        }
        if node["layoutPositioning"]?.stringValue == "ABSOLUTE" {
            parts.append("absolute position")
        }
        return parts.isEmpty ? nil : "sizing: \(parts.joined(separator: ", "))"
    }

    private static func constraints(_ node: JSONValue) -> String? {
        guard let constraints = node["constraints"],
              let horizontal = constraints["horizontal"]?.stringValue,
              let vertical = constraints["vertical"]?.stringValue,
              horizontal != "LEFT" || vertical != "TOP" else {
            return nil
        }
        return "constraints: horizontal \(horizontal.lowercased()), vertical \(vertical.lowercased())"
    }
}
