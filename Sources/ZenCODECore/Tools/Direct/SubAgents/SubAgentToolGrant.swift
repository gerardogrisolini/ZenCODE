//
//  SubAgentToolGrant.swift
//  ZenCODE
//
//  The tool grant of a delegated sub-agent.
//

import Foundation

/// Resolves the tool grant of a delegated sub-agent.
///
/// The order of the steps is part of the authorization boundary:
/// 1. a child with the coordinator's own profile inherits the coordinator's
///    effective grant (`nil`, unrestricted, stays `nil`); any other child
///    starts from its own profile grant;
/// 2. a task-bound child gains the intrinsic task-reporting tools;
/// 3. every child gains the intrinsic prompt-skill tools;
/// 4. the profile's core-tool policy is reapplied (read-only profiles drop
///    mutating core tools, inherited ones included);
/// 5. every child gains the intrinsic collaboration tools, after the policy,
///    so a read-only child keeps `agent.message`.
/// Every union applies only to a restricted grant.
///
/// Pure apart from ``AgentProfile/allowedToolNames()``, which reads the
/// feature statuses and is called only when the child does not inherit.
enum SubAgentToolGrant {
    /// Intrinsic reporting tools of an assigned task attempt.
    static let taskReportingToolNames: Set<String> = [
        "tasks.list", "tasks.get", "tasks.update"
    ]
    /// Intrinsic live-collaboration tools of every delegated agent.
    static let collaborationToolNames: Set<String> = [
        "agent.list", "agent.get", "agent.message"
    ]

    static func resolve(
        parentAllowedToolNames: Set<String>?,
        parentProfileID: String?,
        parentProfileName: String?,
        profile: AgentProfile,
        isTaskBound: Bool
    ) -> Set<String>? {
        var childAllowedToolNames: Set<String>?
        if inheritsParentToolGrant(
            profile: profile,
            parentProfileID: parentProfileID,
            parentProfileName: parentProfileName
        ) {
            // A child with the same resolved profile inherits the
            // coordinator's effective session grant, including
            // session-local additions and removals. A nil parent
            // allowlist remains nil (unrestricted). Payload toolNames
            // is rejected during parsing and never participates here.
            childAllowedToolNames = parentAllowedToolNames
        } else {
            // Different profiles retain their own grant boundary;
            // especially read-only Reviewer/Planner and Minimal must
            // not receive the coordinator's tools accidentally.
            childAllowedToolNames = profile.allowedToolNames()
        }
        if isTaskBound {
            // Assigned task attempts need these intrinsic reporting tools
            // even when the selected profile does not coordinate tasks.
            childAllowedToolNames?.formUnion(taskReportingToolNames)
        }
        // Prompt-skill tools are intrinsic and always-on: every
        // delegated sub-agent must be able to discover and read
        // selected prompt-skill guidance, mirroring the top-level
        // session allowlist resolved by AgentCoreAppSessionFactory.
        childAllowedToolNames?.formUnion(PromptSkillToolProvider.toolNames)
        if let explicitChildAllowedToolNames = childAllowedToolNames {
            childAllowedToolNames = profile.resolvedAllowedToolNames(
                explicitChildAllowedToolNames
            )
        }
        // Live collaboration is intrinsic for every delegated agent.
        // list/get are read-only views of the parent's agent graph;
        // message mutates only the transient in-memory mailbox.
        childAllowedToolNames?.formUnion(collaborationToolNames)
        return childAllowedToolNames
    }

    /// Whether `profile` is the coordinator's own profile: stable IDs are
    /// compared trimmed and case-insensitively; names, the same way, only
    /// when the coordinator has no ID.
    static func inheritsParentToolGrant(
        profile: AgentProfile,
        parentProfileID: String?,
        parentProfileName: String?
    ) -> Bool {
        let normalizedProfileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let parentProfileID = parentProfileID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased(), !parentProfileID.isEmpty {
            // Stable IDs are authoritative. Never compare a coordinator ID
            // with a child name (or vice versa), since those namespaces may
            // legitimately collide.
            return normalizedProfileID == parentProfileID
        }

        guard let parentProfileName = parentProfileName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased(), !parentProfileName.isEmpty else {
            return false
        }
        // Name matching is only a compatibility fallback when no parent ID is
        // available; it remains name-to-name to keep profile boundaries intact.
        let normalizedProfileName = profile.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return normalizedProfileName == parentProfileName
    }
}
