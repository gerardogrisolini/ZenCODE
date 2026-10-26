//
//  AgentDS4Control.swift
//  ZenCODE
//
//  Runtime controls of the in-process DS4 engine that ds4-agent offered as
//  slash commands (`/power`, `/steer`, `/hints`) plus a status report. They are
//  reached through `AgentRuntimeBackend.ds4Control(_:sessionID:)`, which only
//  the backend of a DS4 model implements; every other backend uses the default
//  implementation and rejects the command.
//
//  None of these values is persisted: not in the settings manifest and not in
//  saved sessions. They last as long as the backend that received them.
//

import Foundation

/// A runtime control of the DS4 engine, issued by `/ds4`.
public enum AgentDS4ControlCommand: Sendable, Equatable {
    /// Reports the model, backend, library, context and runtime values.
    case status
    /// Power percentage (1...100) for the current session.
    case power(Int)
    /// Directional-steering FFN scale (-100...100) for the current session;
    /// needs a steering file in the model's runtime configuration.
    case steer(Double)
    /// Brief programming hints on or off, from the next conversation boundary.
    case hints(Bool)

    /// Range accepted by ``power(_:)`` (ds4-agent `parse_power_percent`).
    public static let powerRange = 1...100
    /// Range accepted by ``steer(_:)`` (ds4-agent `parse_steering_level`).
    public static let steeringRange = -100.0...100.0
}

/// Library state of the DS4 engine for the model's root and backend.
public enum AgentDS4LibraryState: String, Sendable, Equatable {
    case built
    case missing
    case stale
}

/// Snapshot reported by ``AgentDS4ControlCommand/status``.
public struct AgentDS4Status: Sendable, Equatable {
    /// Model id the session uses (as shown to the user).
    public var modelID: String
    /// GGUF path relative to the DS4 root, when the runtime names one.
    public var modelRelativePath: String?
    /// Name reported by the open engine; `nil` when the engine is not open.
    public var engineModelName: String?
    /// Stable KV-compatibility model id reported by the open engine.
    public var engineModelID: Int?
    public var engineIsOpen: Bool
    public var backend: String
    /// Library file (built) or the location where it is expected.
    public var libraryPath: String?
    public var libraryState: AgentDS4LibraryState
    /// Tokens in the KV of the current session; `nil` when it is not live.
    public var contextUsedTokens: Int?
    public var contextTotalTokens: Int
    /// Prompt tokens reused from the KV by the last sync of the session.
    public var cachedTokens: Int?
    /// Sessions alive in the engine pool; `nil` when the engine is not open.
    public var liveSessions: Int?
    public var sessionCapacity: Int
    public var powerPercent: Int
    /// `true` when `powerPercent` was set with `/ds4 power`, not configured.
    public var powerIsOverride: Bool
    /// Steering file relative to the DS4 root; `nil` without steering.
    public var steeringFile: String?
    public var steeringScale: Double?
    public var steeringIsOverride: Bool
    /// A value set with `/ds4` that waits for the engine to load.
    public var hasPendingControls: Bool
    public var hintsEnabled: Bool

    public init(
        modelID: String,
        modelRelativePath: String?,
        engineModelName: String? = nil,
        engineModelID: Int? = nil,
        engineIsOpen: Bool,
        backend: String,
        libraryPath: String? = nil,
        libraryState: AgentDS4LibraryState,
        contextUsedTokens: Int? = nil,
        contextTotalTokens: Int,
        cachedTokens: Int? = nil,
        liveSessions: Int? = nil,
        sessionCapacity: Int,
        powerPercent: Int,
        powerIsOverride: Bool = false,
        steeringFile: String? = nil,
        steeringScale: Double? = nil,
        steeringIsOverride: Bool = false,
        hasPendingControls: Bool = false,
        hintsEnabled: Bool = false
    ) {
        self.modelID = modelID
        self.modelRelativePath = modelRelativePath
        self.engineModelName = engineModelName
        self.engineModelID = engineModelID
        self.engineIsOpen = engineIsOpen
        self.backend = backend
        self.libraryPath = libraryPath
        self.libraryState = libraryState
        self.contextUsedTokens = contextUsedTokens
        self.contextTotalTokens = contextTotalTokens
        self.cachedTokens = cachedTokens
        self.liveSessions = liveSessions
        self.sessionCapacity = sessionCapacity
        self.powerPercent = powerPercent
        self.powerIsOverride = powerIsOverride
        self.steeringFile = steeringFile
        self.steeringScale = steeringScale
        self.steeringIsOverride = steeringIsOverride
        self.hasPendingControls = hasPendingControls
        self.hintsEnabled = hintsEnabled
    }

    /// Human readable report, one `Label: value` line per fact (no trailing
    /// newline).
    public var renderedText: String {
        var lines = ["DS4 status"]
        func add(_ label: String, _ value: String) {
            lines.append("  \(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(value)")
        }

        add("Model:", modelID + (modelRelativePath.map { " (\($0))" } ?? ""))
        if engineIsOpen {
            var engine = "open"
            if let engineModelName {
                engine += ": \(engineModelName)"
            }
            if let engineModelID {
                engine += " (model id \(engineModelID))"
            }
            add("Engine:", engine)
        } else {
            add("Engine:", "not open (the model loads with the next prompt)")
        }
        add("Backend:", backend)
        add("Library:", Self.libraryText(state: libraryState, path: libraryPath))

        let total = Self.grouped(contextTotalTokens)
        if let contextUsedTokens {
            let percent = contextTotalTokens > 0
                ? String(format: " (%.1f%%)", Double(contextUsedTokens) * 100 / Double(contextTotalTokens))
                : ""
            add("Context:", "\(Self.grouped(contextUsedTokens)) / \(total) tokens\(percent)")
        } else {
            add("Context:", "0 / \(total) tokens (no live engine state for this session)")
        }
        if let cachedTokens {
            add("KV cache:", "\(Self.grouped(cachedTokens)) tokens reused at the last sync")
        } else {
            add("KV cache:", "empty")
        }
        if let liveSessions {
            add("Sessions:", "\(liveSessions) / \(sessionCapacity) live in the engine pool")
        } else {
            add("Sessions:", "0 / \(sessionCapacity) (engine not open)")
        }

        add("Power:", "\(powerPercent)%" + (powerIsOverride ? " (set with /ds4 power)" : " (configured)"))
        if let steeringFile {
            let scale = steeringScale.map { Self.formatted($0) } ?? "1"
            add(
                "Steering:",
                "FFN \(scale)" + (steeringIsOverride ? " (set with /ds4 steer)" : " (configured)")
                    + ", file \(steeringFile)"
            )
        } else {
            add("Steering:", "off (no steering file configured)")
        }
        if hasPendingControls {
            add("Pending:", "power/steering applies when the model loads, before the next prompt")
        }
        add("Hints:", hintsEnabled ? "on" : "off")
        return lines.joined(separator: "\n")
    }

    private static func libraryText(state: AgentDS4LibraryState, path: String?) -> String {
        switch state {
        case .built:
            return "built" + (path.map { " (\($0))" } ?? "")
        case .missing:
            return "missing" + (path.map { " (expected at \($0); build it from /setup)" } ?? "")
        case .stale:
            return "stale" + (path.map { " (rebuild it at \($0); build it from /setup)" } ?? "")
        }
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }

    static func formatted(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

/// What a control returns: the text the UI shows and, for `status`, the
/// structured snapshot.
public struct AgentDS4ControlResult: Sendable, Equatable {
    /// Renderable text, no trailing newline.
    public var message: String
    public var status: AgentDS4Status?
    /// `false` when a value was stored but still has to reach the engine
    /// (the engine is not open); always `true` for `status` and `hints`.
    public var isApplied: Bool

    public init(message: String, status: AgentDS4Status? = nil, isApplied: Bool = true) {
        self.message = message
        self.status = status
        self.isApplied = isApplied
    }
}

/// Why a DS4 control was rejected.
public enum AgentDS4ControlError: LocalizedError, Equatable, Sendable {
    /// The backend has no in-process DS4 engine (the default implementation).
    case unavailable
    /// No backend is active yet, so no model session exists.
    case noActiveBackend
    /// The session does not exist in the backend.
    case sessionNotFound(String)
    case invalidPower(Int)
    case invalidSteering(Double)
    /// `/ds4 steer` on a model whose runtime has no `steeringRelativePath`.
    case noSteeringFile
    /// The engine refused the change (model without power/steering support, ...).
    case engineRejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "DS4 controls are available only with a DS4 model"
        case .noActiveBackend:
            return "DS4 controls need an active model session"
        case let .sessionNotFound(id):
            return "session \(id) is not available"
        case .invalidPower:
            return "power must be an integer between 1 and 100"
        case .invalidSteering:
            return "steering scale must be a number between -100 and 100"
        case .noSteeringFile:
            return "no steering file configured for this model"
        case let .engineRejected(reason):
            return reason
        }
    }
}
