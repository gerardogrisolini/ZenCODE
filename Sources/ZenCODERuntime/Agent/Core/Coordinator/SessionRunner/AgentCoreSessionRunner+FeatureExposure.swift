//
//  AgentCoreSessionRunner+FeatureExposure.swift
//  ZenCODE
//
//  Lifecycle of the Swift features a Builder sub-agent exposed to a session.
//

import Foundation

/// The agent profile a session runs with, as far as the Builder feature
/// exposures are concerned: a different identity is a profile change.
struct FeatureExposureProfileIdentity: Sendable, Equatable {
    let agentID: String?
    let agentName: String?
    let agentRole: AgentProfileRole?

    init(_ configuration: AgentCoreSessionConfiguration) {
        agentID = configuration.agentID
        agentName = configuration.agentName
        agentRole = configuration.agentRole
    }
}

extension AgentCoreSessionRunner {
    /// Records the profile identity of `configuration`'s session and revokes
    /// the session's exposures unless it is the identity the session already
    /// had: a profile change, or a session created again after its reset or
    /// close, starts without exposures. The same identity (model change,
    /// compaction, option update, `/tools` rebuild) keeps them.
    func reconcileFeatureExposures(with configuration: AgentCoreSessionConfiguration) async {
        let identity = FeatureExposureProfileIdentity(configuration)
        let previous = featureExposureProfileIdentities.updateValue(
            identity,
            forKey: configuration.sessionID
        )
        guard previous != identity else {
            return
        }
        await swiftFeatureRuntime.revokeExposures(sessionID: configuration.sessionID)
    }

    /// Revokes the exposures of `sessionID` when its conversation ends.
    func revokeFeatureExposures(sessionID: String) async {
        featureExposureProfileIdentities.removeValue(forKey: sessionID)
        await swiftFeatureRuntime.revokeExposures(sessionID: sessionID)
    }

    /// Revokes the exposures of every session this runner knows when every
    /// conversation ends (full reset, shutdown): the sessions it created or
    /// updated, the sessions it holds, and `sessionIDs`. The sessions of
    /// another runner that shares the feature runtime keep theirs.
    func revokeKnownFeatureExposures(including sessionIDs: [String] = []) async {
        let knownSessionIDs = Set(featureExposureProfileIdentities.keys)
            .union(sessions.keys)
            .union(lastKnownSessionSnapshots.keys)
            .union(sessionIDs)
        featureExposureProfileIdentities.removeAll()
        for sessionID in knownSessionIDs.sorted() {
            await swiftFeatureRuntime.revokeExposures(sessionID: sessionID)
        }
    }
}
