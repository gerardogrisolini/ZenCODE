//
//  ToolExecutionOutput.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public struct ToolExecutionOutput: Sendable {
    public let text: String
    public let rawResult: JSONValue?

    public init(
        text: String,
        rawResult: JSONValue?
    ) {
        self.text = text
        self.rawResult = rawResult
    }
}
