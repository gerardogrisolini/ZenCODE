import CoreGraphics
import EventKit
import Foundation

/// Shared EventKit access for Calendar and Reminders. Each invocation owns a
/// fresh store; the feature process is one-shot, so nothing is cached.
enum EventKitSupport {
    static func authorizationLabel(for entity: EKEntityType) -> String {
        label(EKEventStore.authorizationStatus(for: entity))
    }

    static func label(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full_access"
        case .writeOnly: return "write_only"
        @unknown default: return "unknown"
        }
    }

    static func eventStore() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw MacOSControlError.permissionRequired(
                "Calendar access is \(authorizationLabel(for: .event)). Grant Full Access to the application hosting ZenCODE in System Settings > Privacy & Security > Calendars, then retry."
            )
        }
        return store
    }

    static func reminderStore() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw MacOSControlError.permissionRequired(
                "Reminders access is \(authorizationLabel(for: .reminder)). Grant access to the application hosting ZenCODE in System Settings > Privacy & Security > Reminders, then retry."
            )
        }
        return store
    }

    /// Resolves a calendar or reminder list by identifier or case-insensitive title.
    static func calendar(
        named selector: String,
        in store: EKEventStore,
        entity: EKEntityType
    ) throws -> EKCalendar {
        let candidates = store.calendars(for: entity)
        let needle = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = candidates.first(where: { $0.calendarIdentifier == needle }) {
            return exact
        }
        let titleMatches = candidates.filter { $0.title.caseInsensitiveCompare(needle) == .orderedSame }
        if titleMatches.count == 1 {
            return titleMatches[0]
        }
        if titleMatches.count > 1 {
            if let writable = titleMatches.first(where: { $0.allowsContentModifications }) {
                return writable
            }
            return titleMatches[0]
        }
        let partial = candidates.filter { $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if partial.count == 1 {
            return partial[0]
        }
        let kind = entity == .event ? "calendar" : "reminder list"
        if partial.count > 1 {
            throw MacOSControlError.ambiguous(
                "Several \(kind)s match '\(selector)': \(partial.map(\.title).joined(separator: ", ")). Use the exact title or the id."
            )
        }
        throw MacOSControlError.notFound(
            "No \(kind) matches '\(selector)'. Available: \(candidates.map(\.title).joined(separator: ", "))."
        )
    }

    static func hexColor(_ color: CGColor?) -> String? {
        guard let color,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = color.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else {
            return nil
        }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func typeLabel(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    static func recurrenceDescription(_ rules: [EKRecurrenceRule]?) -> String? {
        guard let rule = rules?.first else { return nil }
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        var parts = [rule.interval > 1 ? "every \(rule.interval) \(frequency)" : frequency]
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let names = days.map { weekdayName($0.dayOfTheWeek) }
            parts.append("on \(names.joined(separator: ", "))")
        }
        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate, let formatted = MacOSDate.formatDay(endDate) {
                parts.append("until \(formatted)")
            } else if end.occurrenceCount > 0 {
                parts.append("for \(end.occurrenceCount) occurrences")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func weekdayName(_ day: EKWeekday) -> String {
        switch day {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        @unknown default: return "unknown"
        }
    }

    /// Builds a recurrence rule from the simple `recurrence*` arguments.
    static func recurrenceRule(from input: MacOSRunInput) throws -> EKRecurrenceRule? {
        guard let raw = input.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "none" else {
            return nil
        }
        let frequency: EKRecurrenceFrequency
        switch raw {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default:
            throw MacOSControlError.invalidArgument("recurrence", "use daily, weekly, monthly, yearly, or none.")
        }
        let interval = input.recurrence_interval ?? 1
        guard (1...365).contains(interval) else {
            throw MacOSControlError.invalidArgument("recurrence_interval", "must be between 1 and 365.")
        }
        var end: EKRecurrenceEnd?
        if let endDate = try MacOSDate.parse(input.recurrence_end, argument: "recurrence_end", action: input.action) {
            end = EKRecurrenceEnd(end: endDate)
        } else if let count = input.recurrence_count {
            guard count > 0 else {
                throw MacOSControlError.invalidArgument("recurrence_count", "must be a positive integer.")
            }
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    static func alarms(fromMinutes minutes: [Int]?) throws -> [EKAlarm]? {
        guard let minutes else { return nil }
        return try minutes.map { value in
            guard (0...(60 * 24 * 365)).contains(value) else {
                throw MacOSControlError.invalidArgument("alarm_minutes", "each value must be between 0 and 525600 minutes before the start.")
            }
            return EKAlarm(relativeOffset: TimeInterval(-value * 60))
        }
    }

    static func alarmMinutes(_ alarms: [EKAlarm]?) -> [Int]? {
        guard let alarms, !alarms.isEmpty else { return nil }
        return alarms.compactMap { alarm in
            alarm.absoluteDate == nil ? Int((-alarm.relativeOffset / 60).rounded()) : nil
        }
    }

    static func participant(_ participant: EKParticipant?) -> ParticipantInfo? {
        guard let participant else { return nil }
        let status: String
        switch participant.participantStatus {
        case .unknown: status = "unknown"
        case .pending: status = "pending"
        case .accepted: status = "accepted"
        case .declined: status = "declined"
        case .tentative: status = "tentative"
        case .delegated: status = "delegated"
        case .completed: status = "completed"
        case .inProcess: status = "in_process"
        @unknown default: status = "unknown"
        }
        let url = participant.url.absoluteString
        let email = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
        return ParticipantInfo(
            name: participant.name,
            email: email,
            status: status,
            is_current_user: participant.isCurrentUser
        )
    }
}
