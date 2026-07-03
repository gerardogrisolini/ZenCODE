//
//  ThinkingCapability.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated struct ThinkingCapability: Equatable, Sendable {
    public let options: [ThinkingSelection]
    public let defaultSelection: ThinkingSelection

    public init(
        options: [ThinkingSelection],
        defaultSelection: ThinkingSelection
    ) {
        self.options = options
        self.defaultSelection = defaultSelection
    }

    public func selection(for rawValue: String?) -> ThinkingSelection {
        guard let rawValue,
              let requestedSelection = ThinkingSelection(rawValue: rawValue),
              options.contains(requestedSelection) else {
            return defaultSelection
        }

        return requestedSelection
    }
}
