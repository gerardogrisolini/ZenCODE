// Shared runtime-only routing for /plan, /goal, and /review.

import Foundation
import ToolCore

enum CoordinatorCommand: Sendable, Equatable {
    enum PlanAction: Sendable, Equatable {
        case start(goal: String)
        case save
        case load
        case list
        case delete(target: String?)
        case status
        case approve
        case clear
        case missingGoal
    }

    case plan(PlanAction)
    case goal(String)
    case review(String)

    /// Whether this invocation cannot run until the operator supplies an
    /// argument. Frontends use this to request that argument instead of
    /// treating the bare command as a request to execute.
    var requiresArgument: Bool {
        switch self {
        case .plan(.missingGoal): true
        case let .goal(goal): goal.isEmpty
        case .plan, .review: false
        }
    }
}

/// Canonical coordinator command families shared by parsing and frontend menus.
enum CoordinatorCommandFamily: String, CaseIterable, Sendable {
    case plan
    case goal
    case review

    var menuDescription: String {
        switch self {
        case .plan: "Plan work and continue planning questions"
        case .goal: "Work until the goal is complete or genuinely blocked"
        case .review: "Review the current changes"
        }
    }
}

/// Parses the command families that must behave identically in every frontend.
/// It deliberately does not treat unrelated slash commands or `@mentions` as
/// planning replies; those remain owned by their transport-specific routers.
enum CoordinatorCommandParser {
    static func parse(_ input: String) -> CoordinatorCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let tokenEnd = trimmed.firstIndex(where: \Character.isWhitespace)
            ?? trimmed.endIndex
        let rawToken = String(trimmed[..<tokenEnd]).lowercased()
        let token: String
        if let atSign = rawToken.firstIndex(of: "@"),
           atSign != rawToken.startIndex,
           rawToken.index(after: atSign) != rawToken.endIndex {
            token = String(rawToken[..<atSign])
        } else {
            token = rawToken
        }
        let argument = String(trimmed[tokenEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let family = CoordinatorCommandFamily(rawValue: String(token.dropFirst())) else {
            return nil
        }
        switch family {
        case .goal:
            return .goal(argument)
        case .plan:
            return .plan(planAction(argument))
        case .review:
            return .review(argument)
        }
    }

    static func isSlashCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private static func planAction(_ argument: String) -> CoordinatorCommand.PlanAction {
        guard !argument.isEmpty else { return .missingGoal }
        let normalized = argument.lowercased()
        switch normalized {
        case "save": return .save
        case "load": return .load
        case "list": return .list
        case "status": return .status
        case "approve": return .approve
        case "clear": return .clear
        case "delete": return .delete(target: nil)
        default:
            if normalized.hasPrefix("delete ") {
                let target = argument.dropFirst("delete".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .delete(target: target.nilIfBlank)
            }
            return .start(goal: argument)
        }
    }
}
