//
//  ZenTranscriptStatus.swift
//  ZenApp
//
//  Status glyphs and color roles of tasks, task graphs, and sub-agents,
//  mirroring the terminal UI's task and sub-agent overviews.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The status color roles of `ZenPalette` (`TerminalStyle.Status`).
public enum ZenStatusRole: Sendable, Equatable, CaseIterable {
    case queued
    case active
    case success
    case failure
    case inactive

    /// The palette color of the role.
    public func color(in palette: ZenPalette) -> Color {
        switch self {
        case .queued: palette.statusQueued
        case .active: palette.statusActive
        case .success: palette.statusSuccess
        case .failure: palette.statusFailure
        case .inactive: palette.statusInactive
        }
    }
}

/// One colored fragment of an overview's summary line, such as `✓ 3 completed`.
public struct ZenStatusSegment: Sendable, Equatable {
    public let text: String
    /// The color role, or `nil` for the muted text color.
    public let role: ZenStatusRole?

    public init(text: String, role: ZenStatusRole?) {
        self.text = text
        self.role = role
    }
}

/// Status presentation of tasks, task graphs, and sub-agents.
public enum ZenTranscriptStatus {
    // MARK: - Tasks

    /// The color role of a task status: pending in the queued color, running
    /// in the active color, completed in the success color, failed and blocked
    /// in the failure color, awaiting validation and cancelled inactive.
    public static func role(for status: TaskStatus) -> ZenStatusRole {
        switch status {
        case .pending: .queued
        case .inProgress: .active
        case .completed: .success
        case .failed, .blocked: .failure
        case .awaitingValidation, .cancelled: .inactive
        @unknown default: .inactive
        }
    }

    /// The glyph the terminal's task overview gives a task status.
    public static func glyph(for status: TaskStatus) -> String {
        switch status {
        case .completed: "✓"
        case .inProgress: "▸"
        case .awaitingValidation: "◇"
        case .blocked: "⊘"
        case .failed: "✗"
        case .cancelled: "—"
        case .pending: "○"
        @unknown default: "·"
        }
    }

    /// The color role of a task graph's state.
    public static func role(for state: TaskGraphState) -> ZenStatusRole {
        switch state {
        case .draft: .queued
        case .active: .active
        case .completed: .success
        case .cancelled, .archived: .inactive
        @unknown default: .inactive
        }
    }

    /// The summary line of a task overview: the total, then the non-zero
    /// counts of running, completed, awaiting validation, waiting, blocked,
    /// and failed tasks, in the terminal's order.
    public static func taskSummarySegments(_ tasks: [TaskRecordView]) -> [ZenStatusSegment] {
        func count(_ status: TaskStatus) -> Int {
            tasks.filter { $0.task.status == status }.count
        }
        let counted: [(Int, String, TaskStatus)] = [
            (count(.inProgress), "running", .inProgress),
            (count(.completed), "completed", .completed),
            (count(.awaitingValidation), "awaiting validation", .awaitingValidation),
            (count(.pending), "waiting", .pending),
            (count(.blocked), "blocked", .blocked),
            (count(.failed), "failed", .failed)
        ]
        return [ZenStatusSegment(text: "\(tasks.count) total", role: nil)]
            + counted.filter { $0.0 > 0 }.map { number, label, status in
                ZenStatusSegment(text: "\(glyph(for: status)) \(number) \(label)", role: role(for: status))
            }
    }

    // MARK: - Sub-agents

    /// The status a sub-agent row shows: `completed` for an idle agent that
    /// produced output, otherwise the runtime status.
    public static func displayStatus(for snapshot: DirectSubAgentRuntime.AgentSnapshot) -> String {
        if snapshot.status == .idle, ZenTranscriptText.nonBlank(snapshot.latestOutput) != nil {
            return "completed"
        }
        return snapshot.status.rawValue
    }

    /// The color role of a sub-agent, as the terminal's overview colors it.
    public static func role(for snapshot: DirectSubAgentRuntime.AgentSnapshot) -> ZenStatusRole {
        switch snapshot.status {
        case .queued: .queued
        case .running: .active
        case .idle: ZenTranscriptText.nonBlank(snapshot.latestOutput) == nil ? .inactive : .success
        case .standby, .closed: .inactive
        case .failed: .failure
        @unknown default: .inactive
        }
    }

    /// The summary line of a sub-agent overview, in the terminal's order.
    public static func subAgentSummarySegments(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [ZenStatusSegment] {
        let completed = snapshots.filter {
            $0.status == .idle && ZenTranscriptText.nonBlank($0.latestOutput) != nil
        }.count
        func count(_ status: DirectSubAgentRuntime.Status) -> Int {
            snapshots.filter { $0.status == status }.count
        }
        let counted: [(Int, String, ZenStatusRole?)] = [
            (snapshots.filter(\.pending).count, "▸ %d active", .active),
            (completed, "✓ %d completed", .success),
            (count(.standby), "◇ %d standby", .inactive),
            (count(.failed), "✗ %d failed", .failure),
            (count(.closed), "· %d closed", nil)
        ]
        return [ZenStatusSegment(text: "\(snapshots.count) total", role: nil)]
            + counted.filter { $0.0 > 0 }.map { number, format, role in
                ZenStatusSegment(
                    text: format.replacingOccurrences(of: "%d", with: String(number)),
                    role: role
                )
            }
    }

    /// A token count as the terminal abbreviates it: `950`, `12.3k`, `1.2m`.
    public static func tokenCountText(_ value: Int) -> String {
        let magnitude = abs(value)
        let locale = Locale(identifier: "en_US_POSIX")
        if magnitude >= 1_000_000 {
            return String(format: "%.1fm", locale: locale, Double(value) / 1_000_000)
        }
        if magnitude >= 1_000 {
            return String(format: "%.1fk", locale: locale, Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// An elapsed wall-clock interval: `12s`, `3m 05s`, `1h 02m`.
    public static func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3_600 {
            return String(format: "%dm %02ds", seconds / 60, seconds % 60)
        }
        return String(format: "%dh %02dm", seconds / 3_600, (seconds % 3_600) / 60)
    }
}
