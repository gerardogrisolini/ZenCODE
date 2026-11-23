import CoreGraphics
import Foundation
import ToolCore

/// Pure logic behind list_windows: summary and note composition, and the
/// conservative pairing of Quartz windows with Accessibility windows. Live
/// reads live in `DesktopController.enrichedWithAccessibility`.
enum DesktopWindowListing {
    struct Text: Equatable {
        let summary: String
        let note: String?
    }

    static let screenRecordingNote = "Without Screen Recording permission, some window titles may be unavailable."
    static let hostFallbackName = "the app that launched zen"
    /// Overall deadline, in seconds, of the Accessibility enrichment.
    static let accessibilityBudget: Double = 3
    static let accessibilityTimeoutNote = "Some apps did not answer Accessibility requests within the \(Int(accessibilityBudget))-second budget, so subrole, is_main, is_focused, and is_minimized are missing for some windows."

    static let maximumOutputTitleCharacters = 160
    static let maximumOutputAppNameCharacters = 80

    static func outputText(_ text: String?, cap: Int) -> String? {
        guard let text, text.count > cap else { return text }
        return String(text.prefix(cap - 3)) + "..."
    }

    /// Bounds only a window returned to the model. Selection and ref anchors
    /// keep using the integral Quartz/AX title and application identity.
    static func projected(_ window: DesktopWindowInfo) -> DesktopWindowInfo {
        var result = window
        result.title = outputText(result.title, cap: maximumOutputTitleCharacters)
        result.app_name = outputText(result.app_name, cap: maximumOutputAppNameCharacters)
        result.bundle_id = outputText(result.bundle_id, cap: 200)
        return result
    }

    static func scopePhrase(_ window: DesktopWindowInfo) -> String {
        let app = window.app_name ?? (window.pid > 0 ? "pid \(window.pid)" : nil)
        if let title = window.title?.nilIfBlank {
            return "the window '\(title)'" + (app.map { " of \($0)" } ?? "")
        }
        if let app { return "the untitled window of \(app)" }
        return "the frontmost window"
    }

    /// Summary and note for the windows actually returned. Everything is English,
    /// like the rest of the tool output.
    ///
    /// - Parameters:
    ///   - frontmostAppName: name of the frontmost app, or nil when there is none.
    ///   - hostAppName: name of the app hosting this zen session, if known.
    ///   - screenRecordingGranted: whether Screen Recording is authorized.
    ///   - accessibilityTimedOut: whether the Accessibility enrichment stopped
    ///     at its deadline.
    ///   - offset: the position of the first window in the whole list.
    ///   - nextOffset: the `offset` that continues the list, when more windows remain.
    static func text(
        windows: [DesktopWindowInfo],
        frontmostAppName: String?,
        hostAppName: String?,
        screenRecordingGranted: Bool,
        accessibilityTimedOut: Bool = false,
        offset: Int = 0,
        nextOffset: Int? = nil
    ) -> Text {
        var summary = "Listed \(windows.count) window(s)\(offset > 0 ? " from offset \(offset)" : "") in front-to-back order."
        if let name = frontmostAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            summary += " Frontmost app: \(name)."
        }
        let offScreen = windows.filter { !$0.is_on_screen }.count
        if offScreen > 0 {
            summary += " \(offScreen) of them are not on screen (minimized, hidden, or on another Space)."
        }
        if let nextOffset {
            summary += " More windows remain (next_offset=\(nextOffset))."
        }

        var notes: [String] = []
        let hostWindows = windows.filter { $0.hosts_zen == true }
        if !hostWindows.isEmpty {
            let name = hostWindows.lazy.compactMap { $0.app_name?.nilIfBlank }.first
                ?? hostAppName?.nilIfBlank
                ?? hostFallbackName
            notes.append("Windows marked hosts_zen belong to \(name), which runs this zen session; they are not the app to control.")
        }
        if !screenRecordingGranted {
            notes.append(screenRecordingNote)
        }
        if accessibilityTimedOut {
            notes.append(accessibilityTimeoutNote)
        }
        return Text(summary: summary, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Accessibility attributes of one window, applied only when it is paired.
    struct AXAttributes: Equatable {
        var subrole: String?
        var isMain: Bool?
        var isFocused: Bool?
        var isMinimized: Bool?
    }

    /// For each Quartz window, the index of its Accessibility window, or nil
    /// unless the pairing is unique in both directions. The relation is
    /// `DesktopSafetyPolicy.matches` (title + frame) read the same way in both
    /// directions, so a Quartz window without a title (no Screen Recording)
    /// still pairs by frame. Duplicates on either side leave the AX fields nil
    /// rather than risk attributing them to the wrong window.
    ///
    /// `quartz` must hold every window of the app that could compete for an AX
    /// window (for example before applying `limit`).
    static func pairing(
        quartz: [DesktopSafetyPolicy.WindowIdentity],
        ax: [DesktopSafetyPolicy.WindowIdentity]
    ) -> [Int?] {
        quartz.indices.map { quartzIndex in
            let axMatches = ax.indices.filter { DesktopSafetyPolicy.matches(ax[$0], quartz[quartzIndex]) }
            guard axMatches.count == 1, let axIndex = axMatches.first else { return nil }
            let quartzMatches = quartz.indices.filter { DesktopSafetyPolicy.matches(ax[axIndex], quartz[$0]) }
            return quartzMatches == [quartzIndex] ? axIndex : nil
        }
    }

    static func applying(_ attributes: AXAttributes, to window: DesktopWindowInfo) -> DesktopWindowInfo {
        var enriched = window
        enriched.subrole = attributes.subrole?.nilIfBlank
        enriched.is_main = attributes.isMain
        enriched.is_focused = attributes.isFocused ?? window.is_focused
        enriched.is_minimized = attributes.isMinimized ?? window.is_minimized
        return enriched
    }
}
