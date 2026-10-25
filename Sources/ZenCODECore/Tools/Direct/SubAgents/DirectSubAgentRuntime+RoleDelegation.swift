//
//  DirectSubAgentRuntime+RoleDelegation.swift
//  ZenCODE
//
//  Role-based delegation: `agent.create` items that name a `profileRole`
//  instead of an explicit profile.
//

import Foundation

/// Supplies the configured agent profiles that role-based delegation
/// (`agent.create` with `profileRole`) chooses from.
public typealias DirectSubAgentProfileCatalogProvider = @Sendable () -> [AgentProfile]

extension DirectSubAgentRuntime {
    /// Production catalog: the persisted profiles. Missing or invalid profiles
    /// fail closed (no candidate). `loadRequired` takes no manifest lock, so it
    /// is safe inside `SensitiveManifestCoordination.withExclusiveLock`.
    public static func liveProfileCatalogProvider() -> [AgentProfile] {
        (try? AgentProfileStore.loadRequired()) ?? []
    }

    /// Resolves `role` to a profile visible to the project and to one of its
    /// delegatable model bindings, applying `TaskRecord.agentSelectionPolicy`
    /// over the union of the candidates' bindings: the lowest capability that
    /// meets `complexity`, otherwise the highest capability (a capability gap).
    /// Ties prefer the role's system profile, then manifest order, then the
    /// order of `delegatableBindings` (the roster order: model ID, then binding
    /// ID). When no candidate has a delegatable binding, a
    /// candidate without configured bindings inherits the main session model.
    ///
    /// Pure: every input, including the catalog snapshot, is supplied by the
    /// caller so the result is bound to the batch's authoritative snapshot.
    static func resolvingProfileRole(
        for payload: RequestedAgentPayload,
        role: AgentProfileRole,
        complexity: Int,
        profiles: [AgentProfile],
        projectSelection: Set<String>?,
        projectPath: String,
        snapshot: AgentDelegationCatalogSnapshot
    ) throws -> (payload: RequestedAgentPayload, profile: AgentProfile, note: String) {
        let candidates = AgentProfileStore.roleDelegationCandidates(
            role,
            in: profiles,
            projectSelection: projectSelection
        )
        guard !candidates.isEmpty else {
            throw DirectSubAgentRuntimeError.agentProfileRoleNotAvailableForProject(
                role,
                projectPath
            )
        }

        struct Pair {
            let candidateIndex: Int
            let bindingIndex: Int
            let profile: AgentProfile
            let binding: ResolvedAgentModelBinding

            var capability: Int { binding.capability ?? 0 }

            /// Tie-break among equal capabilities.
            func isPreferred(over other: Pair) -> Bool {
                if profile.isSystemProfile != other.profile.isSystemProfile {
                    return profile.isSystemProfile
                }
                if candidateIndex != other.candidateIndex {
                    return candidateIndex < other.candidateIndex
                }
                return bindingIndex < other.bindingIndex
            }
        }

        let pairs = candidates.enumerated().flatMap { candidateIndex, profile in
            AgentDelegationCatalog.resolvedBindings(for: profile, snapshot: snapshot)
                .delegatableBindings
                .enumerated()
                .map { bindingIndex, binding in
                    Pair(
                        candidateIndex: candidateIndex,
                        bindingIndex: bindingIndex,
                        profile: profile,
                        binding: binding
                    )
                }
        }
        let notePrefix = "Resolved profileRole \"\(role.rawValue)\" for agent "
            + "\"\(payload.name)\" (complexity \(complexity)) to profile"

        guard !pairs.isEmpty else {
            let unboundCandidates = candidates.filter { $0.modelBindings.isEmpty }
            guard let profile = unboundCandidates.first(where: \.isSystemProfile)
                ?? unboundCandidates.first else {
                throw DirectSubAgentRuntimeError.agentProfileRoleHasNoRoutableBinding(
                    role,
                    candidates.map(\.displayName)
                )
            }
            return (
                payload: payload.applying(
                    profileReference: profile.id,
                    modelBinding: nil,
                    modelSelection: nil
                ),
                profile: profile,
                note: "\(notePrefix) \"\(profile.displayName)\" inheriting the main "
                    + "session model (no configured bindings)."
            )
        }

        let sufficient = pairs.filter { $0.capability >= complexity }
        let pool = sufficient.isEmpty ? pairs : sufficient
        let targetCapability = sufficient.isEmpty
            ? pool.map(\.capability).max()
            : pool.map(\.capability).min()
        guard let chosen = pool
            .filter({ $0.capability == targetCapability })
            .min(by: { $0.isPreferred(over: $1) }) else {
            throw DirectSubAgentRuntimeError.agentProfileRoleHasNoRoutableBinding(
                role,
                candidates.map(\.displayName)
            )
        }

        guard let modelSelection = snapshot.modelSelection(for: chosen.binding) else {
            throw DirectSubAgentRuntimeError.modelBindingUnavailable(
                modelID: chosen.binding.selectionReference,
                profile: chosen.profile.displayName,
                reason: "the resolved provider configuration is incomplete"
            )
        }

        var note = "\(notePrefix) \"\(chosen.profile.displayName)\" with model "
            + "\(chosen.binding.selectionReference) (capability \(chosen.capability)/10)."
        if sufficient.isEmpty, payload.taskID == nil {
            // Task-bound items are covered by the post-claim advisory, which
            // compares the task complexity with the selected capability.
            note += " Warning: capability gap of \(complexity - chosen.capability); "
                + "no authorized binding with this role meets the complexity in this project."
        }
        return (
            payload: payload.applying(
                profileReference: chosen.profile.id,
                modelBinding: chosen.binding.routingBinding,
                modelSelection: modelSelection
            ),
            profile: chosen.profile,
            note: note
        )
    }
}
