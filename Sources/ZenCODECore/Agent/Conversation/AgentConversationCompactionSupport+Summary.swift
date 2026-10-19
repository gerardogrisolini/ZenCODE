//
//  AgentConversationCompactionSupport+Summary.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension AgentConversationCompactionSupport {
    /// Compacts `text` to `limit` characters. Beyond
    /// `tailPreservationCharacters` both the head and the tail are kept, so a
    /// fact stated at the end of a long message is not systematically lost.
    public static func compactSummaryText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, limit > 0 else {
            return ""
        }

        guard normalized.count > limit else {
            return normalized
        }

        let marker = "..."
        // A marker cannot fit in one to three characters; honour the limit exactly with the prefix.
        guard limit > marker.count else {
            return String(normalized.prefix(limit))
        }
        guard limit > AgentConversationCompactionPolicy.tailPreservationCharacters else {
            let cutoff = limit - marker.count
            let cutoffIndex = normalized.index(normalized.startIndex, offsetBy: cutoff)
            let truncated = normalized[..<cutoffIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(truncated)\(marker)"
        }

        let available = limit - marker.count - 2
        let headLimit = max(Int(Double(available) * 0.65), 1)
        let tailLimit = max(available - headLimit, 1)
        let headIndex = normalized.index(normalized.startIndex, offsetBy: headLimit)
        let tailIndex = normalized.index(normalized.endIndex, offsetBy: -tailLimit)
        let head = normalized[..<headIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = normalized[tailIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(head) \(marker) \(tail)"
    }

    struct SummaryEntry {
        var prefix: String
        var text: String
        var weight: Double
    }

    /// Pre-flattened summary entries with per-message prefix offsets, so every
    /// candidate evaluation can slice the older-message entries instead of
    /// rebuilding (and re-trimming) them.
    struct SummaryEntrySource {
        let entries: [SummaryEntry]
        let prefixCounts: [Int]

        init(conversationMessages: [AgentRuntimeMessage]) {
            var entries: [SummaryEntry] = []
            var prefixCounts: [Int] = [0]
            entries.reserveCapacity(conversationMessages.count)
            prefixCounts.reserveCapacity(conversationMessages.count + 1)
            for message in conversationMessages {
                entries.append(contentsOf: AgentConversationCompactionSupport.summaryEntries(for: message))
                prefixCounts.append(entries.count)
            }
            self.entries = entries
            self.prefixCounts = prefixCounts
        }

        func entries(forOlderMessageCount count: Int) -> [SummaryEntry] {
            let clamped = min(max(count, 0), prefixCounts.count - 1)
            return Array(entries[0..<prefixCounts[clamped]])
        }
    }

    static func normalizedPriorSummary(_ summary: String?) -> String? {
        guard var summary = summary?.nilIfBlank else {
            return nil
        }
        if let headerRange = summary.range(of: memorySummaryHeader) {
            summary.removeSubrange(headerRange)
        }
        let isDelimited = summary.contains("\n" + memorySummaryInstruction)
        summary = summary.split(separator: "\n").filter {
            $0 != memorySummaryInstruction && $0 != legacyMemorySummaryInstruction
        }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Current summaries hold escaped single-line data: strip exactly our quote
        // prefix, never nest. Legacy lines are escaped first, never interpreted.
        return summary.split(separator: "\n").map { line in
            let value = String(line)
            if isDelimited, value.hasPrefix(historicalLinePrefix) {
                return String(value.dropFirst(historicalLinePrefix.count))
            }
            return isDelimited ? value : escapedHistoricalText(value)
        }.joined(separator: "\n").nilIfBlank
    }

    /// Removes every leading `Prior memory:` label from an inherited line.
    ///
    /// Historical summaries wrote the inherited memory inline as
    /// `Prior memory: <text>`; re-emitting such a line under a fresh label
    /// would nest the marker once per compaction. Both the inline legacy form
    /// and the current standalone-label form normalise to the bare fact.
    static func strippingPriorMemoryLabels(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(priorMemoryLabel) {
            value = String(value.dropFirst(priorMemoryLabel.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Splits inherited memory back into its individual facts. Nested and
    /// inline "Prior memory:" labels are dropped so repeated compactions never
    /// stack them.
    static func priorSummaryEntries(from priorSummary: String) -> [SummaryEntry] {
        priorSummary
            .split(separator: "\n")
            .map { strippingPriorMemoryLabels(String($0)) }
            .filter { !$0.isEmpty }
            .map { SummaryEntry(prefix: historicalLinePrefix, text: $0, weight: 1.2) }
    }

    /// Escape data before truncation. No literal line breaks, markup delimiters
    /// or stable summary marker can be injected into the structural envelope.
    /// This is provenance separation, not semantic prompt-injection detection.
    static func escapedHistoricalText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0...31, 127...159, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069,
                 60, 62, 92:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.replacingOccurrences(
            of: memorySummaryHeader,
            with: "Conversation memory summary from earlier turns\\u{2e}"
        )
    }

    static func summaryEntries(
        for message: AgentRuntimeMessage
    ) -> [SummaryEntry] {
        var entries: [SummaryEntry] = []
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleLabel = roleLabel(message.role)
        if !content.isEmpty {
            entries.append(
                SummaryEntry(
                    prefix: "\(historicalLinePrefix)\(roleLabel): ",
                    text: escapedHistoricalText(content),
                    weight: summaryWeight(for: message.role)
                )
            )
        }
        let mediaSummary = mediaSummary(for: message)
        if !mediaSummary.isEmpty {
            entries.append(
                SummaryEntry(
                    prefix: "\(historicalLinePrefix)\(roleLabel) media: ",
                    text: escapedHistoricalText(mediaSummary),
                    weight: 0.2
                )
            )
        }
        return entries
    }

    static func naturalCharacterCost(of entries: [SummaryEntry]) -> Int {
        entries.reduce(into: 0) { $0 += $1.prefix.count + $1.text.count + 1 }
    }

    /// Renders the summary within `maxCharacters`.
    ///
    /// No floor is applied here: the public entry point and `bestCandidate`
    /// both honour the budget they were given, including values below the
    /// historical `minimumSummaryCharacters` reference.
    static func conversationMemorySummary(
        priorSummary: String?,
        entries: [SummaryEntry],
        maxCharacters: Int
    ) -> String {
        let budget = max(maxCharacters, 0)
        guard budget > 0 else {
            return ""
        }

        // Facts are emitted only with their trust instruction and quoted provenance;
        // tiny budgets keep just the stable marker.
        let fullHeader = """
        \(memorySummaryHeader)
        \(memorySummaryInstruction)
        """
        let header: String
        if fullHeader.count + 1 <= budget {
            header = fullHeader
        } else if memorySummaryHeader.count <= budget {
            header = memorySummaryHeader
        } else {
            header = compactSummaryText(memorySummaryHeader, limit: budget)
        }

        guard header == fullHeader else { return header }
        let priorEntries = normalizedPriorSummary(priorSummary)
            .map(priorSummaryEntries(from:)) ?? []
        let hasPrior = !priorEntries.isEmpty
        let hasNewFacts = !entries.isEmpty
        guard hasPrior || hasNewFacts else {
            return header
        }

        // Reserve the body separator now so every section allowance is exact.
        let bodyBudget = max(budget - header.count - 1, 0)
        guard bodyBudget > 0 else {
            return header
        }

        let priorLabelCost = priorEntries.isEmpty ? 0 : priorMemoryLabel.count + 1
        let priorNaturalCost = priorEntries.isEmpty
            ? 0
            : naturalCharacterCost(of: priorEntries) + priorLabelCost
        let newNaturalCost = naturalCharacterCost(of: entries)

        func priorBlock(withBudget sectionBudget: Int) -> String {
            guard hasPrior, sectionBudget > priorLabelCost else {
                return ""
            }
            let facts = summaryLines(
                for: priorEntries,
                budget: sectionBudget - priorLabelCost,
                densePacking: true
            )
            guard !facts.isEmpty else {
                return ""
            }
            return "\(priorMemoryLabel)\n\(facts.joined(separator: "\n"))"
        }

        func newFactsBlock(withBudget sectionBudget: Int) -> String {
            summaryLines(for: entries, budget: sectionBudget)
                .joined(separator: "\n")
        }

        let body: String
        if hasPrior && hasNewFacts {
            // Reserve separator, label and first provenance prefix BEFORE sharing
            // the content allowance, so prior facts aren't penalised for their label.
            let sectionsBudget = max(bodyBudget - 1, 0)
            let priorStructure = min(
                sectionsBudget,
                priorLabelCost + (priorEntries.first?.prefix.count ?? 0)
            )
            let newStructure = min(
                max(sectionsBudget - priorStructure, 0),
                entries.first?.prefix.count ?? 0
            )
            let contentBudget = max(sectionsBudget - priorStructure - newStructure, 0)
            var priorBudget = min(priorNaturalCost, priorStructure + contentBudget / 2)
            var newFactsBudget = sectionsBudget - priorBudget

            // Allocation the new material cannot consume goes to inherited memory,
            // after its own non-zero share is reserved.
            if newNaturalCost < newFactsBudget {
                priorBudget = min(
                    priorNaturalCost,
                    priorBudget + (newFactsBudget - newNaturalCost)
                )
                newFactsBudget = sectionsBudget - priorBudget
            }

            let prior = priorBlock(withBudget: priorBudget)
            let newFacts = newFactsBlock(withBudget: newFactsBudget)
            body = [prior, newFacts].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if hasPrior {
            body = priorBlock(withBudget: bodyBudget)
        } else {
            body = newFactsBlock(withBudget: bodyBudget)
        }

        guard !body.isEmpty else {
            return header
        }
        // `summaryLines` honours each allowance. The prefix is retained as a
        // last-resort contract guard for future formatter changes.
        return String("\(header)\n\(body)".prefix(budget))
    }

    /// Distributes the summary budget across the whole history instead of
    /// keeping only its chronological prefix, so both the earliest decisions
    /// and the facts stated right before the raw window survive.
    static func summaryLines(
        for entries: [SummaryEntry],
        budget: Int,
        densePacking: Bool = false
    ) -> [String] {
        guard !entries.isEmpty, budget > 0 else {
            return []
        }

        // Raw history stays lean; distilled inherited facts pack at natural density.
        // No elision sentence: it would consume a variable part of the budget.
        let perEntryBudget: Int
        if densePacking {
            perEntryBudget = max(naturalCharacterCost(of: entries) / entries.count, 1)
        } else {
            perEntryBudget = AgentConversationCompactionPolicy.minimumSummaryEntryCharacters
        }
        var maximumEntryCount = min(entries.count, max(budget / perEntryBudget, 1))

        func sampledEntries(count: Int) -> [SummaryEntry] {
            guard count < entries.count else {
                return entries
            }
            guard count > 1 else {
                return [entries[0]]
            }
            let step = Double(entries.count - 1) / Double(count - 1)
            var indices: [Int] = []
            for position in 0..<count {
                let index = min(Int((Double(position) * step).rounded()), entries.count - 1)
                if indices.last != index {
                    indices.append(index)
                }
            }
            return indices.map { entries[$0] }
        }

        var selected = sampledEntries(count: maximumEntryCount)
        while !selected.isEmpty {
            let structuralCost = selected.enumerated().reduce(into: 0) { cost, pair in
                cost += pair.element.prefix.count
                if pair.offset > 0 {
                    cost += 1 // newline between adjacent lines
                }
            }
            let textBudget = budget - structuralCost
            if textBudget >= selected.count {
                var limits = selected.map { min($0.text.count, 1) }
                var remainingBudget = textBudget - limits.reduce(0, +)
                var remainingWeight = selected.reduce(into: 0.0) { total, entry in
                    total += entry.weight
                }

                for index in selected.indices {
                    let entry = selected[index]
                    let capacity = max(entry.text.count - limits[index], 0)
                    let share = remainingWeight > 0
                        ? Int((Double(remainingBudget) * entry.weight / remainingWeight).rounded(.down))
                        : remainingBudget
                    let additional = min(capacity, max(share, 0))
                    limits[index] += additional
                    remainingBudget -= additional
                    remainingWeight = max(remainingWeight - entry.weight, 0)
                }

                // Give budget left by capacity-limited early entries to later ones.
                for index in selected.indices.reversed() where remainingBudget > 0 {
                    let capacity = max(selected[index].text.count - limits[index], 0)
                    let additional = min(capacity, remainingBudget)
                    limits[index] += additional
                    remainingBudget -= additional
                }

                return selected.enumerated().compactMap { index, entry in
                    let text = compactSummaryText(entry.text, limit: limits[index])
                    guard !text.isEmpty else {
                        return nil
                    }
                    return "\(entry.prefix)\(text)"
                }
            }

            guard maximumEntryCount > 1 else {
                return []
            }
            maximumEntryCount -= 1
            selected = sampledEntries(count: maximumEntryCount)
        }
        return []
    }

    static func roleLabel(_ role: AgentRuntimeMessage.Role) -> String {
        switch role {
        case .system: "System"
        case .user: "User request"
        case .assistant: "Assistant reply"
        case .tool: "Tool result"
        }
    }

    static func mediaSummary(for message: AgentRuntimeMessage) -> String {
        let imageCount = message.attachments.filter { $0.kind == .image }.count
        let videoCount = message.attachments.filter { $0.kind == .video }.count
        var parts: [String] = []
        if imageCount > 0 { parts.append("\(imageCount) image(s)") }
        if videoCount > 0 { parts.append("\(videoCount) video(s)") }
        return parts.joined(separator: ", ")
    }

    static func summaryWeight(for role: AgentRuntimeMessage.Role) -> Double {
        switch role {
        case .user: 1.4
        case .assistant: 1.1
        case .tool: 0.8
        case .system: 1.0
        }
    }
}
