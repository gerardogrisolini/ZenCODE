//
//  FigmaVariableCollector.swift
//  ZenCODE
//
//  Collects the styles and variables a node subtree uses, with the values
//  applied in the design, and resolves variable names through the Figma
//  Variables REST API when the token and plan allow it.
//

import Foundation
import ToolCore

struct FigmaVariableCollector {
    struct StyleUsage: Equatable {
        let id: String
        let slot: String
        let value: String?
    }

    struct VariableUsage: Equatable {
        let id: String
        let property: String
        let value: String?
    }

    private(set) var styles: [StyleUsage] = []
    private(set) var variables: [VariableUsage] = []

    mutating func collect(_ node: JSONValue) {
        for (slot, reference) in (node["styles"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let id = reference.stringValue, !styles.contains(where: { $0.id == id }) else { continue }
            styles.append(StyleUsage(id: id, slot: slot, value: Self.styleValue(slot: slot, node: node)))
        }
        if let bound = node["boundVariables"] {
            collectAliases(in: bound, path: [], node: node)
        }
        for paintKey in ["fills", "strokes"] {
            for (index, paint) in (node[paintKey]?.arrayValue ?? []).enumerated() {
                if let bound = paint["boundVariables"] {
                    collectAliases(in: bound, path: [paintKey, String(index)], node: node)
                }
            }
        }
        for child in node["children"]?.arrayValue ?? [] {
            collect(child)
        }
    }

    private mutating func collectAliases(in value: JSONValue, path: [String], node: JSONValue) {
        switch value {
        case let .object(object):
            if object["type"]?.stringValue == "VARIABLE_ALIAS", let id = object["id"]?.stringValue {
                guard !variables.contains(where: { $0.id == id }) else { return }
                variables.append(VariableUsage(
                    id: id,
                    property: path.first ?? "value",
                    value: Self.appliedValue(path: path, node: node)
                ))
                return
            }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                collectAliases(in: child, path: path + [key], node: node)
            }
        case let .array(array):
            for (index, child) in array.enumerated() {
                collectAliases(in: child, path: path + [String(index)], node: node)
            }
        default:
            return
        }
    }

    /// Value the design applies for a bound property, used when variable
    /// definitions are unavailable.
    static func appliedValue(path: [String], node: JSONValue) -> String? {
        guard let property = path.first else { return nil }
        if property == "fills" || property == "strokes" {
            let paints = node[property]?.arrayValue ?? []
            if path.count > 1, let index = Int(path[1]), paints.indices.contains(index) {
                return FigmaFormat.paint(paints[index])
            }
            return FigmaFormat.paints(node[property]).first
        }
        if let number = node[property]?.numberValue ?? node["style"]?[property]?.numberValue {
            return FigmaFormat.number(number)
        }
        return node[property]?.stringValue ?? node["style"]?[property]?.stringValue
    }

    static func styleValue(slot: String, node: JSONValue) -> String? {
        switch slot.lowercased() {
        case "fill", "fills":
            let paints = FigmaFormat.paints(node["fills"])
            return paints.isEmpty ? nil : paints.joined(separator: ", ")
        case "stroke", "strokes":
            let paints = FigmaFormat.paints(node["strokes"])
            return paints.isEmpty ? nil : paints.joined(separator: ", ")
        case "text":
            return node["style"].map(FigmaFormat.fontDefinition)
        case "effect", "effects":
            let effects = FigmaFormat.effects(node["effects"])
            return effects.isEmpty ? nil : "Effect(\(effects.joined(separator: "; ")))"
        case "grid":
            return "LayoutGrid"
        default:
            return nil
        }
    }

    /// Builds the name -> value dictionary. `stylesMetadata` is the `styles`
    /// map of the nodes response; `variablesResponse` is the optional
    /// `/variables/local` payload.
    func definitions(
        stylesMetadata: [String: JSONValue],
        variablesResponse: JSONValue?
    ) -> (definitions: [String: String], unresolvedVariableCount: Int) {
        var result: [String: String] = [:]
        for style in styles {
            let name = stylesMetadata[style.id]?["name"]?.stringValue ?? style.id
            result[uniqueKey(name, in: result)] = style.value ?? "(no value applied)"
        }

        let meta = variablesResponse?["meta"]
        let variableMap = meta?["variables"]?.objectValue ?? [:]
        let collections = meta?["variableCollections"]?.objectValue ?? [:]
        var unresolved = 0
        for usage in variables {
            if let variable = variableMap[usage.id] {
                let name = variable["name"]?.stringValue ?? usage.id
                let value = Self.resolvedValue(of: variable, variables: variableMap, collections: collections)
                result[uniqueKey(name, in: result)] = value ?? usage.value ?? "(unresolved)"
            } else {
                unresolved += 1
                result[uniqueKey("\(usage.id) (\(usage.property))", in: result)] = usage.value ?? "(unresolved)"
            }
        }
        return (result, unresolved)
    }

    /// Value in the collection's default mode, following aliases.
    static func resolvedValue(
        of variable: JSONValue,
        variables: [String: JSONValue],
        collections: [String: JSONValue],
        hops: Int = 0
    ) -> String? {
        guard hops < 8 else { return nil }
        let modes = variable["valuesByMode"]?.objectValue ?? [:]
        let collectionID = variable["variableCollectionId"]?.stringValue
        let defaultMode = collectionID.flatMap { collections[$0]?["defaultModeId"]?.stringValue }
        guard let value = defaultMode.flatMap({ modes[$0] }) ?? modes.sorted(by: { $0.key < $1.key }).first?.value else {
            return nil
        }
        if value["type"]?.stringValue == "VARIABLE_ALIAS", let target = value["id"]?.stringValue {
            guard let next = variables[target] else { return "alias \(target)" }
            return resolvedValue(of: next, variables: variables, collections: collections, hops: hops + 1)
        }
        switch variable["resolvedType"]?.stringValue {
        case "COLOR":
            return FigmaFormat.hex(value)
        case "FLOAT":
            return value.numberValue.map(FigmaFormat.number)
        case "BOOLEAN":
            return value.boolValue.map { $0 ? "true" : "false" }
        default:
            return value.flexibleStringValue
        }
    }

    private func uniqueKey(_ name: String, in dictionary: [String: String]) -> String {
        guard dictionary[name] != nil else { return name }
        var index = 2
        while dictionary["\(name) (\(index))"] != nil { index += 1 }
        return "\(name) (\(index))"
    }
}
