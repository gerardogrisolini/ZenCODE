//
//  DirectToolExecutor+FeatureExposure.swift
//  ZenCODE
//
//  Session exposure of the Swift features a Builder sub-agent built: the
//  identity gate of the registration, the session whose exposures an
//  executor reads, and the announcement on `agent.*` results.
//

import Foundation
import ToolCore

extension DirectToolExecutor {
    /// The session to expose a feature this executor builds to: the session
    /// that delegated it, when this executor belongs to a sub-agent with the
    /// `builder` role; `nil` for every other executor, which therefore never
    /// registers an exposure. Derived from the identity the runtime set when
    /// the sub-agent was created, never from model output.
    var featureExposureDelegatingSessionID: String? {
        guard toolExecutionContext.isSubAgent,
              toolExecutionContext.profileRole == .builder else {
            return nil
        }
        return toolExecutionContext.delegatingSessionID?.nilIfBlank
    }

    /// The session whose feature exposures apply to a call made in
    /// `sessionID`: the delegating session for a sub-agent created with the
    /// coordinator's own profile under a restricted grant
    /// (``ToolExecutionContext/inheritsFeatureExposures``), so it sees the
    /// same features by ID and loses them when that session's exposures are
    /// revoked; `sessionID` for every other executor. Derived from the
    /// identity the runtime set when the sub-agent was created.
    func featureExposureSessionID(for sessionID: String?) -> String? {
        guard toolExecutionContext.isSubAgent,
              toolExecutionContext.inheritsFeatureExposures,
              let delegatingSessionID = toolExecutionContext.delegatingSessionID?.nilIfBlank else {
            return sessionID
        }
        return delegatingSessionID
    }

    /// `output` of an `agent.*` call, followed by the announcement of the
    /// exposures of `sessionID` not announced yet, if any. Each exposure is
    /// announced once.
    func appendingFeatureExposureAnnouncement(
        to output: String,
        sessionID: String?
    ) async -> String {
        guard sessionID?.nilIfBlank != nil else {
            return output
        }
        let exposures = await swiftFeatureRuntime.takeUnannouncedExposures(sessionID: sessionID)
        guard let announcement = SwiftFeatureRuntime.featureExposureAnnouncement(
            for: exposures
        ) else {
            return output
        }
        return output.isEmpty ? announcement : "\(output)\n\n\(announcement)"
    }
}
