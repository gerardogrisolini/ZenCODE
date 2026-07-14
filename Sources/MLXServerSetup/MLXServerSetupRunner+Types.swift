//
//  MLXServerSetupRunner+Types.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import MLXServerCore

struct SetupSectionOption {
    let section: SetupSection
    let detail: String?
}

enum SetupSection: Equatable {
    case kvCache
    case diskKVCache
    case finish
    case cancel

    var title: String {
        switch self {
        case .kvCache:
            return "In-memory KV cache"
        case .diskKVCache:
            return "Disk KV cache"
        case .finish:
            return "Finish setup"
        case .cancel:
            return "Cancel without saving"
        }
    }

    func matches(_ value: String) -> Bool {
        aliases.contains(value)
    }

    private var aliases: Set<String> {
        switch self {
        case .kvCache:
            return ["kv", "kv cache", "memory kv", "in-memory kv cache", "cache"]
        case .diskKVCache:
            return ["disk", "disk kv", "disk kv cache", "persistent kv"]
        case .finish:
            return ["finish", "done", "exit", "quit", "end", "stop"]
        case .cancel:
            return ["cancel", "abort", "discard", "quit without saving"]
        }
    }
}

enum MLXServerSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed
    case invalidChoice(String)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Local MLX runtime setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during ZenCODE MLX setup."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        }
    }
}

enum KVCacheProfile: Int, CaseIterable {
    case bestPerformance = 1
    case balanced = 2
    case lowMemory = 3
    case longSessions = 4
    case custom = 5

    static var allowedRange: ClosedRange<Int> {
        guard let first = allCases.first?.rawValue,
              let last = allCases.last?.rawValue else {
            return 1...1
        }
        return first...last
    }

    static func matching(_ settings: MLXServerKVCacheSettings) -> Self? {
        allCases.first { $0.presetSettings == settings }
    }

    var title: String {
        switch self {
        case .bestPerformance:
            return "Best Performance"
        case .balanced:
            return "Balanced"
        case .lowMemory:
            return "Low Memory"
        case .longSessions:
            return "Long Sessions"
        case .custom:
            return "Custom"
        }
    }

    var presetSettings: MLXServerKVCacheSettings? {
        switch self {
        case .bestPerformance:
            MLXServerKVCacheSettings(mode: .standard)
        case .balanced:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 1_024
            )
        case .lowMemory:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 0
            )
        case .longSessions:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 2_048
            )
        case .custom:
            nil
        }
    }
}

enum MLXServerSetupInputParser {
    static let maximumPathLength = 4_096

    static func parseDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let decimalSeparatorCount = trimmed.reduce(into: 0) { count, character in
            if character == "." || character == "," {
                count += 1
            }
        }
        guard decimalSeparatorCount <= 1 else {
            return nil
        }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".", options: .literal)
        guard let parsed = Double(normalized), parsed.isFinite else {
            return nil
        }
        return parsed
    }

    static func isValidLength(_ value: String, maximumLength: Int?) -> Bool {
        guard let maximumLength else {
            return true
        }
        return value.count <= maximumLength
    }
}
