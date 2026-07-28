//
//  FeatureTool.swift
//  ZenCODE
//

import Foundation
import ToolCore

public protocol FeatureTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: String { get }
    static var outputSchema: String? { get }
    static var presentation: ToolPresentationDefinition { get }

    func run(_ input: Input, context: FeatureContext) async throws -> Output
}

public extension FeatureTool {
    static var outputSchema: String? {
        nil
    }

}
