//
//  MLXServerSetupRunner+Prompting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore
import MLXServerCore

extension MLXServerSetupRunner {
    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        maximumLength: Int? = nil,
        isSecure: Bool = false
    ) throws -> String {
        _ = isSecure
        while true {
            guard let value = TerminalCheckboxMenu.promptLine(
                title: "ZenCODE MLX setup",
                prompt: prompt,
                defaultValue: defaultValue,
                allowEmpty: allowEmpty
            ) else {
                throw MLXServerSetupError.inputClosed
            }
            if !MLXServerSetupInputParser.isValidLength(value, maximumLength: maximumLength) {
                AgentOutput.standardError.writeString(
                    "Invalid value: maximum length is \(maximumLength ?? 0) characters.\n"
                )
                continue
            }
            return value
        }
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

    static func promptDouble(
        _ prompt: String,
        defaultValue: Double,
        allowedRange: ClosedRange<Double>
    ) throws -> Double {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(format: "%.0f", defaultValue),
                allowEmpty: false
            )
            guard let parsed = MLXServerSetupInputParser.parseDouble(value),
                  allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
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
