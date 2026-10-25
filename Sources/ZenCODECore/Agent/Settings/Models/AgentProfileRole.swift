//
//  AgentProfileRole.swift
//  ZenCODE
//
//  Role of an agent profile: the only property that determines which kind of
//  agent a profile is. A profile's ID and name carry no meaning.
//

import Foundation

/// The fixed list of agent roles. Every profile has exactly one, persisted in
/// the required `role` field of `agents.json`.
///
/// - `developer`: the default agent when none is selected.
/// - `builder`: owns `/feature` and the feature-management tools.
/// - `minimal`, `reporter`, `organizer`, `promoter`: no runtime semantics
///   beyond their profile's own configuration.
/// - `planner`: `/plan` delegates to it and its core tools are forced
///   read-only.
/// - `reviewer`: `/review` delegates to it.
///
/// The recommended (system) profile of each role has the role as its ID; see
/// ``AgentProfile/isSystemProfile``.
public enum AgentProfileRole: String, Codable, Sendable, CaseIterable, Hashable {
    case developer
    case builder
    case minimal
    case planner
    case reviewer
    case reporter
    case organizer
    case promoter

    /// Human-readable title.
    public var title: String {
        switch self {
        case .developer: "Developer"
        case .builder: "Builder"
        case .minimal: "Minimal"
        case .planner: "Planner"
        case .reviewer: "Reviewer"
        case .reporter: "Reporter"
        case .organizer: "Organizer"
        case .promoter: "Promoter"
        }
    }

    /// Short description shown by `/setup` and `/agents`.
    public var summary: String {
        switch self {
        case .developer: "General software development; the default agent"
        case .builder: "/feature and the feature-management tools"
        case .minimal: "Essential tools and concise replies"
        case .planner: "/plan delegates to it; core tools are forced read-only"
        case .reviewer: "/review delegates to it"
        case .reporter: "Evidence-based code analysis reports"
        case .organizer: "Personal assistant with macOS apps, memory, and delegation"
        case .promoter: "Daily project promotion with browser drafts and memory"
        }
    }

    /// Comma-separated list of every valid persisted value.
    static var allowedValuesDescription: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// Decoding failure of a profile's required `role` field. The manifest that
/// contains it is invalid.
public enum AgentProfileRoleDecodingError: LocalizedError, Equatable {
    case missing(profile: String)
    case invalid(profile: String, value: String?)

    public var errorDescription: String? {
        switch self {
        case let .missing(profile):
            return "profile '\(profile)' is missing the required \"role\" field "
                + "(one of: \(AgentProfileRole.allowedValuesDescription))."
        case let .invalid(profile, value):
            let shown = value.map { " '\($0)'" } ?? ""
            return "profile '\(profile)' has an invalid \"role\" value\(shown) "
                + "(one of: \(AgentProfileRole.allowedValuesDescription))."
        }
    }
}

extension AgentProfileStore {
    /// Every profile with `role`, in their order.
    public static func roleProfiles(
        _ role: AgentProfileRole,
        in profiles: [AgentProfile]
    ) -> [AgentProfile] {
        profiles.filter { $0.role == role }
    }

    /// Profiles a role-driven command (`/plan`, `/review`) may delegate to:
    /// every profile with `role` that is visible to the project (see
    /// ``ProjectAgentSelectionStore/filter(_:selection:)``). With several, the
    /// model chooses among them. An empty result means the command must stop.
    static func roleDelegationCandidates(
        _ role: AgentProfileRole,
        in profiles: [AgentProfile],
        projectSelection: Set<String>?
    ) -> [AgentProfile] {
        roleProfiles(
            role,
            in: ProjectAgentSelectionStore.filter(profiles, selection: projectSelection)
        )
    }

    static func roleDelegationCandidates(
        _ role: AgentProfileRole,
        in profiles: [AgentProfile],
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> [AgentProfile] {
        roleDelegationCandidates(
            role,
            in: profiles,
            projectSelection: ProjectAgentSelectionStore.load(
                workspaceRootURL: workspaceRootURL,
                fileManager: fileManager
            )
        )
    }

    /// Error shown when no profile visible to the project has the role a
    /// command needs.
    static func roleUnavailableForProjectMessage(_ role: AgentProfileRole) -> String {
        "ZenCODE: no agent profile with the \(role.rawValue) role is available for this project. "
            + "Tick one with /agents."
    }

    /// Profile clause of a hidden delegation prompt. A single candidate keeps
    /// the historical `profile "<id>"` wording; several candidates are all
    /// listed and the model may use any of them.
    static func delegationProfileClause(_ profiles: [AgentProfile]) -> String {
        guard profiles.count > 1 else {
            return "profile \"\(profiles.first?.id ?? "")\""
        }
        let candidates = profiles
            .map { "\"\($0.id)\" (\($0.displayName))" }
            .joined(separator: ", ")
        return "one of these profiles (any of them is acceptable): \(candidates)"
    }
}
