// Strict Planner text validation and structured todo/task projections.

import Foundation
import ToolCore

extension PlanningCommandKernel {
    static func plan(
        _ plan: TerminalSessionPlan,
        applying graph: TaskGraphSnapshot
    ) -> TerminalSessionPlan {
        var projected = plan
        let tasksByID = Dictionary(uniqueKeysWithValues: graph.tasks.map { ($0.id, $0) })
        for index in projected.points.indices {
            guard let task = tasksByID[projected.points[index].id] else { continue }
            projected.points[index].status = planPointStatus(for: task.status)
            projected.points[index].dependsOn = task.dependsOn
        }
        return projected
    }

    static func planPointStatus(
        for status: TaskStatus
    ) -> TerminalSessionPlanPointStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .awaitingValidation: .awaitingValidation
        case .completed: .completed
        case .blocked: .blocked
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    /// Validates the coordinator's bootstrap independently of task-graph
    /// creation. A final Planner turn must describe the same ordered points it
    /// registered, with explicit, closed, acyclic dependencies.
    static func structuredPlanOutputIsCoherent(
        text: String,
        points: [TerminalSessionPlanPoint]
    ) -> Bool {
        guard !points.isEmpty,
              points.allSatisfy({
                  $0.hasExplicitDependencies && $0.status == .pending
              }) else {
            return false
        }
        let ids = points.map(\.id)
        let idSet = Set(ids)
        let prefixes = points.enumerated().compactMap { index, point in
            planIDPrefix(point.id, expectedOrdinal: index + 1)
        }
        guard idSet.count == ids.count,
              prefixes.count == points.count,
              Set(prefixes).count == 1,
              points.allSatisfy({ point in
                  Set(point.dependsOn).count == point.dependsOn.count
                      && point.dependsOn.allSatisfy { dependency in
                          dependency != point.id && idSet.contains(dependency)
                      }
              }), dependenciesAreAcyclic(points) else {
            return false
        }

        guard let describedPoints = implementationPoints(in: text),
              describedPoints.count == points.count else {
            return false
        }
        return zip(describedPoints, points).enumerated().allSatisfy { index, pair in
            let (described, point) = pair
            let normalizedDescription = normalizedPlanComparisonText(described.text)
            let normalizedPoint = normalizedPlanComparisonText(point.text)
            guard !normalizedDescription.isEmpty, !normalizedPoint.isEmpty else {
                return false
            }
            guard described.dependencyOrdinals.allSatisfy({ ordinal in
                ordinal > 0 && ordinal <= points.count && ordinal != index + 1
            }) else {
                return false
            }
            let describedDependencies = described.dependencyOrdinals.map {
                points[$0 - 1].id
            }
            return normalizedPoint == normalizedDescription
                && point.dependsOn == describedDependencies
        }
    }

    /// Derives ordered plan points **strictly** from a final Planner message.
    ///
    /// This is the shared fallback used when the coordinator produced a valid
    /// final plan but never registered it through the expected `todo.write`
    /// call. Nothing is relaxed: the text must still declare `Specifiche
    /// concordate`, a numbered `Implementation plan` and an explicit
    /// `Dependencies:` line for every point, and the derived points must pass
    /// exactly the same coherence validation applied to registered points.
    /// Any malformed or incoherent output yields `nil`.
    static func planPoints(
        derivedFromFinalText text: String,
        identifierToken: String = UUID().uuidString.lowercased()
    ) -> [TerminalSessionPlanPoint]? {
        guard !isPlannerQuestionResponse(text) else { return nil }
        let token = identifierToken.filter { $0.isLetter || $0.isNumber }
        guard !token.isEmpty,
              let described = implementationPoints(in: text),
              !described.isEmpty,
              described.allSatisfy({ item in
                  item.dependencyOrdinals.allSatisfy { $0 > 0 && $0 <= described.count }
              }) else {
            return nil
        }
        let ids = described.indices.map { "plan-\(token)-\($0 + 1)" }
        // Parsing enforces nonempty text and unique ordinals; the shared validator
        // below still rejects self-dependencies, cycles, and incoherent output.
        let points = described.enumerated().map { index, item in
            TerminalSessionPlanPoint(
                id: ids[index],
                text: item.text,
                dependsOn: item.dependencyOrdinals.map { ids[$0 - 1] },
                hasExplicitDependencies: true
            )
        }
        guard structuredPlanOutputIsCoherent(text: text, points: points) else {
            return nil
        }
        return points
    }

    /// One plan of a final Planner output. A multi-plan output has one section
    /// per `Piano N/M` heading; a heading-less output is a single section whose
    /// `heading` is `nil` and whose `text` is the original text unchanged.
    struct PlanSection: Equatable, Sendable {
        let heading: String?
        let text: String
        let points: [TerminalSessionPlanPoint]
    }

    /// Splits a final Planner output into its plan sections. Without any
    /// sequence heading the text is one heading-less section, unchanged. With
    /// headings, the first non-blank line must be a heading and the headings
    /// must be numbered 1...M with the same total M equal to their count;
    /// otherwise the output is malformed and `nil` is returned. Each section
    /// spans from its heading (included) to the next one (excluded), trimmed.
    static func planSectionTexts(
        in text: String
    ) -> [(heading: String?, text: String)]? {
        let lines = text.components(separatedBy: "\n")
        let headings = lines.indices.compactMap { index in
            planSequenceHeading(lines[index]).map { (index: index, value: $0) }
        }
        guard let firstHeading = headings.first else { return [(nil, text)] }
        guard lines.firstIndex(where: { $0.nilIfBlank != nil }) == firstHeading.index,
              headings.enumerated().allSatisfy({ offset, heading in
                  heading.value.number == offset + 1
                      && heading.value.total == headings.count
              }) else {
            return nil
        }
        return headings.enumerated().map { offset, heading in
            let end = offset + 1 < headings.count ? headings[offset + 1].index : lines.count
            return (
                heading.value.heading,
                lines[heading.index..<end]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Matches registered points to the plan sections of a final Planner
    /// output. Points are grouped by ID prefix in order, one group per section,
    /// and every section must be coherent with its own group, so dependencies
    /// across plans, interleaved groups, or a section/group count mismatch
    /// yield `nil`. A heading-less output is equivalent to
    /// `structuredPlanOutputIsCoherent(text:points:)` on the whole text.
    static func planSections(
        forFinalText text: String,
        registeredPoints: [TerminalSessionPlanPoint]
    ) -> [PlanSection]? {
        guard let sectionTexts = planSectionTexts(in: text),
              let groups = planPointGroups(registeredPoints),
              groups.count == sectionTexts.count else {
            return nil
        }
        var sections: [PlanSection] = []
        for (section, points) in zip(sectionTexts, groups) {
            guard structuredPlanOutputIsCoherent(text: section.text, points: points) else {
                return nil
            }
            sections.append(PlanSection(heading: section.heading, text: section.text, points: points))
        }
        return sections
    }

    /// Derives every plan section strictly from a final Planner output, each
    /// with its own fresh identifier token. Questions or any malformed section
    /// yield `nil`.
    static func planSections(
        derivedFromFinalText text: String
    ) -> [PlanSection]? {
        guard !isPlannerQuestionResponse(text),
              let sectionTexts = planSectionTexts(in: text) else {
            return nil
        }
        var sections: [PlanSection] = []
        for section in sectionTexts {
            guard let points = planPoints(derivedFromFinalText: section.text) else {
                return nil
            }
            sections.append(PlanSection(heading: section.heading, text: section.text, points: points))
        }
        return sections
    }

    /// The goal of one plan in a sequence carries its heading so the plans
    /// stay distinguishable; a heading-less plan keeps the goal unchanged.
    static func planGoal(_ goal: String, for section: PlanSection) -> String {
        guard let heading = section.heading else { return goal }
        return "\(heading) — \(goal)"
    }

    /// Groups points by ID prefix (the ID without its trailing `-<Int>`),
    /// preserving order. An ID without a numeric suffix, or a prefix that
    /// reappears after another group, yields `nil`.
    private static func planPointGroups(
        _ points: [TerminalSessionPlanPoint]
    ) -> [[TerminalSessionPlanPoint]]? {
        var groups: [(prefix: String, points: [TerminalSessionPlanPoint])] = []
        var seenPrefixes = Set<String>()
        for point in points {
            let components = point.id.split(separator: "-", omittingEmptySubsequences: false)
            guard components.count > 1, let last = components.last, Int(last) != nil else {
                return nil
            }
            let prefix = components.dropLast().joined(separator: "-")
            if groups.last?.prefix == prefix {
                groups[groups.count - 1].points.append(point)
            } else {
                guard seenPrefixes.insert(prefix).inserted else { return nil }
                groups.append((prefix, [point]))
            }
        }
        return groups.map(\.points)
    }

    private struct DescribedImplementationPoint {
        let text: String
        let dependencyOrdinals: [Int]
    }

    private static func planIDPrefix(
        _ id: String,
        expectedOrdinal: Int
    ) -> String? {
        let components = id.split(separator: "-", omittingEmptySubsequences: false)
        let tokenComponents = components.dropFirst().dropLast()
        guard components.count >= 3,
              components.first == "plan",
              tokenComponents.allSatisfy({ component in
                  !component.isEmpty
                      && component.allSatisfy { $0.isLetter || $0.isNumber }
              }),
              components.last == Substring(String(expectedOrdinal)) else {
            return nil
        }
        return components.dropLast().joined(separator: "-")
    }

    private static func dependenciesAreAcyclic(
        _ points: [TerminalSessionPlanPoint]
    ) -> Bool {
        let dependencies = Dictionary(
            uniqueKeysWithValues: points.map { ($0.id, $0.dependsOn) }
        )
        var visiting = Set<String>()
        var visited = Set<String>()

        func visit(_ id: String) -> Bool {
            if visited.contains(id) { return true }
            guard visiting.insert(id).inserted else { return false }
            for dependency in dependencies[id] ?? [] {
                guard visit(dependency) else { return false }
            }
            visiting.remove(id)
            visited.insert(id)
            return true
        }

        return points.allSatisfy { visit($0.id) }
    }

    private static func implementationPoints(
        in text: String
    ) -> [DescribedImplementationPoint]? {
        var foundSpecifications = false
        var foundSection = false
        var points: [DescribedImplementationPoint] = []
        var textLines: [String] = []
        var dependencies: [Int]?

        func appendCurrentPoint() -> Bool {
            guard !textLines.isEmpty, let dependencies else { return false }
            points.append(
                DescribedImplementationPoint(
                    text: textLines.joined(separator: "\n"),
                    dependencyOrdinals: dependencies
                )
            )
            return true
        }

        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHeading = trimmed
                .drop(while: { $0 == "#" || $0.isWhitespace })
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                .lowercased()
            if !foundSection {
                if normalizedHeading == "specifiche concordate" {
                    foundSpecifications = true
                } else if normalizedHeading == "implementation plan",
                          foundSpecifications {
                    foundSection = true
                }
                continue
            }
            if trimmed.hasPrefix("#"), !textLines.isEmpty {
                guard appendCurrentPoint() else { return nil }
                textLines.removeAll(keepingCapacity: false)
                break
            }
            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            if leadingSpaces <= 3,
               !rawLine.prefix(while: { $0.isWhitespace }).contains("\t"),
               let numbered = numberedPlanHeading(from: trimmed) {
                if !textLines.isEmpty {
                    guard appendCurrentPoint() else { return nil }
                    textLines.removeAll(keepingCapacity: true)
                    dependencies = nil
                }
                guard numbered.number == points.count + 1 else { return nil }
                textLines.append(numbered.text)
                continue
            }
            guard !textLines.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("dependencies:") {
                guard dependencies == nil,
                      let parsed = parsedPlanDependencies(from: trimmed) else {
                    return nil
                }
                dependencies = parsed
            } else if !trimmed.isEmpty {
                textLines.append(trimmed)
            }
        }
        if foundSection, !textLines.isEmpty {
            guard appendCurrentPoint() else { return nil }
        }
        return foundSection && !points.isEmpty ? points : nil
    }

    private static func parsedPlanDependencies(from line: String) -> [Int]? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let rawValue = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        if normalized == "none" || normalized == "[]" {
            return []
        }
        let cleaned = rawValue
            .replacingOccurrences(of: ",", with: " ")
            .filter { !"`[]().".contains($0) }
        let tokens = cleaned.split(whereSeparator: \Character.isWhitespace)
        let ordinals = tokens.compactMap { Int($0) }
        guard !tokens.isEmpty,
              ordinals.count == tokens.count,
              ordinals.allSatisfy({ $0 > 0 }),
              Set(ordinals).count == ordinals.count else {
            return nil
        }
        return ordinals
    }

    private static func numberedPlanHeading(
        from text: String
    ) -> (number: Int, text: String)? {
        guard let delimiter = text.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(text[..<delimiter]) else {
            return nil
        }
        let remainder = text[text.index(after: delimiter)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        return (number, remainder)
    }

    private static func normalizedPlanComparisonText(_ text: String) -> String {
        let withoutNumber = numberedPlanHeading(
            from: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.text ?? text
        return withoutNumber
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func planPointUpdates(
        from toolCall: DirectAgentToolCall
    ) -> (points: [TerminalSessionPlanPoint], mode: DirectTodoTaskRuntime.TodoWriteMode)? {
        let request = DirectTodoTaskRuntime.normalizedToolRequest(for: toolCall)
        guard request.name == "todo.write",
              let todos = try? DirectTodoTaskRuntime.requestedTodos(from: request.arguments) else {
            return nil
        }
        let points = todos.compactMap { todo -> TerminalSessionPlanPoint? in
            let id = todo.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = todo.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.hasPrefix("plan-"), !text.isEmpty else { return nil }
            let status: TerminalSessionPlanPointStatus
            switch todo.status {
            case .pending: status = .pending
            case .inProgress: status = .inProgress
            case .completed: status = .completed
            case .blocked: status = .blocked
            }
            return TerminalSessionPlanPoint(
                id: id,
                text: text,
                status: status,
                dependsOn: todo.dependsOn ?? [],
                hasExplicitDependencies: todo.dependsOn != nil
            )
        }
        guard !points.isEmpty, points.count == todos.count else { return nil }
        return (
            points,
            DirectTodoTaskRuntime.TodoWriteMode(
                rawValue: DirectTodoTaskRuntime.firstString(["mode"], in: request.arguments)
            )
        )
    }

    static func planID(from points: [TerminalSessionPlanPoint]) -> String {
        guard let firstID = points.first?.id.nilIfBlank else {
            return "plan-\(UUID().uuidString.lowercased())"
        }
        let components = firstID.split(separator: "-", omittingEmptySubsequences: false)
        if components.count > 1,
           components.last.flatMap({ Int($0) }) != nil {
            return components.dropLast().joined(separator: "-")
        }
        return "plan-\(UUID().uuidString.lowercased())"
    }

    static func taskDefinitions(
        for points: [TerminalSessionPlanPoint]
    ) -> [TaskDefinition] {
        points.enumerated().map { index, point in
            TaskDefinition(
                id: point.id,
                title: point.text,
                order: index + 1,
                dependsOn: point.dependsOn
            )
        }
    }
}
