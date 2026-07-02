//
//  MLXServerModelSetupRunner+Prompting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String? = nil
    ) throws -> String {
        guard let value = TerminalCheckboxMenu.promptLine(
            title: "ZenCODE MLX models setup",
            prompt: prompt,
            defaultValue: defaultValue,
            allowEmpty: allowEmpty,
            help: help
        ) else {
            throw MLXServerModelSetupError.inputClosed
        }
        return value
    }


    static func promptInt(
        _ prompt: String,
        defaultValue: Int,
        allowedRange: ClosedRange<Int>
    ) throws -> Int {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Int(value), allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    static func promptFloat(
        _ prompt: String,
        defaultValue: Float,
        allowedRange: ClosedRange<Float>
    ) throws -> Float {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: formatFloat(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Float(value.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    static func formatFloat(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
            TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
        ]
        return TerminalCheckboxMenu.selectOne(
            title: prompt,
            items: items,
            selected: defaultValue
        ) ?? defaultValue
    }


    static func supportsInteractiveInput() -> Bool {
        MLXServerSetupInteractiveLineReader.supportsInteractiveInput()
    }
}
