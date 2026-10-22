import EventKit
import Foundation

enum RemindersController {
    private struct Snapshot: Sendable {
        let info: ReminderInfo
        let due: Date?
        let created: Date?
        let completion: Date?
    }

    static func lists(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { list in
                ReminderListInfo(
                    id: list.calendarIdentifier,
                    title: list.title,
                    source: list.source?.title,
                    color: EventKitSupport.hexColor(list.cgColor),
                    allows_modifications: list.allowsContentModifications,
                    is_default: list.calendarIdentifier == defaultID
                )
            }
        var output = MacOSRunOutput(action: .remindersLists, summary: "\(lists.count) reminder lists.")
        output.reminder_lists = lists
        output.count = lists.count
        return output
    }

    static func list(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        var calendars: [EKCalendar]?
        if let selector = input.list {
            calendars = [try EventKitSupport.calendar(named: selector, in: store, entity: .reminder)]
        }
        let statusFilter = (input.status ?? "incomplete").lowercased()
        guard ["incomplete", "completed", "all"].contains(statusFilter) else {
            throw MacOSControlError.invalidArgument("status", "use incomplete (default), completed, or all.")
        }
        let dueAfter = try MacOSDate.parse(input.since ?? input.start, argument: "since", action: input.action)
        var dueBefore = try MacOSDate.parse(input.until ?? input.end, argument: "until", action: input.action)
        if let resolved = dueBefore, MacOSDate.isDateOnly(input.until ?? input.end) {
            dueBefore = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: resolved))
        }
        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDueRange = dueAfter != nil || dueBefore != nil
        let includeUndated = input.include_undated ?? false

        let predicate = store.predicateForReminders(in: calendars)
        let snapshots = await fetch(predicate, store: store)
        var excludedUndated = 0
        var matched = snapshots.filter { snapshot in
            switch statusFilter {
            case "incomplete": if snapshot.info.completed { return false }
            case "completed": if !snapshot.info.completed { return false }
            default: break
            }
            if let query, !query.isEmpty {
                let haystack = [snapshot.info.title, snapshot.info.notes]
                guard haystack.contains(where: { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else {
                    return false
                }
            }
            if hasDueRange {
                guard let due = snapshot.due else {
                    if includeUndated { return true }
                    excludedUndated += 1
                    return false
                }
                if let dueAfter, due < dueAfter { return false }
                if let dueBefore, due >= dueBefore { return false }
            }
            return true
        }
        matched.sort { left, right in
            if left.info.completed != right.info.completed {
                return !left.info.completed
            }
            switch (left.due, right.due) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return (left.created ?? .distantPast) < (right.created ?? .distantPast)
            }
        }
        let limit = input.boundedLimit(default: 100, maximum: 500)
        let total = matched.count
        var summary = "\(total) \(statusFilter == "all" ? "" : statusFilter + " ")reminders" + (total > limit ? " (showing \(limit))." : ".")
        if excludedUndated > 0 {
            summary += " \(excludedUndated) matching reminder\(excludedUndated == 1 ? "" : "s") without a due date \(excludedUndated == 1 ? "was" : "were") excluded by the since/until filter; pass include_undated=true or drop the date bounds to see \(excludedUndated == 1 ? "it" : "them")."
        }
        var output = MacOSRunOutput(action: .remindersList, summary: summary)
        output.reminders = matched.prefix(limit).map(\.info)
        output.count = total
        return output
    }

    static func create(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        let title = try input.require(input.title, "title")
        let reminder = EKReminder(eventStore: store)
        if let selector = input.list {
            reminder.calendar = try EventKitSupport.calendar(named: selector, in: store, entity: .reminder)
        } else if let defaultList = store.defaultCalendarForNewReminders() {
            reminder.calendar = defaultList
        } else {
            throw MacOSControlError.operationFailed("No default reminder list is configured; pass list explicitly.")
        }
        guard reminder.calendar.allowsContentModifications else {
            throw MacOSControlError.invalidArgument("list", "'\(reminder.calendar.title)' is read-only.")
        }
        reminder.title = title
        try apply(input, to: reminder)
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Reminders refused to save the reminder: \(error.localizedDescription)")
        }
        var output = MacOSRunOutput(
            action: .remindersCreate,
            summary: "Created reminder '\(title)' in '\(reminder.calendar.title)'"
                + (reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.flatMap { MacOSDate.format($0) }.map { " due \($0)" } ?? "")
                + "."
        )
        output.reminder = info(reminder)
        return output
    }

    static func update(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        let reminder = try resolve(input, store: store)
        if let title = input.title {
            reminder.title = title
        }
        if let selector = input.list {
            let target = try EventKitSupport.calendar(named: selector, in: store, entity: .reminder)
            guard target.allowsContentModifications else {
                throw MacOSControlError.invalidArgument("list", "'\(target.title)' is read-only.")
            }
            reminder.calendar = target
        }
        try apply(input, to: reminder)
        if let completed = input.completed {
            reminder.isCompleted = completed
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Reminders refused to update the reminder: \(error.localizedDescription)")
        }
        var output = MacOSRunOutput(action: .remindersUpdate, summary: "Updated reminder '\(reminder.title ?? "")'.")
        output.reminder = info(reminder)
        return output
    }

    static func complete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        let reminder = try resolve(input, store: store)
        let completed = input.completed ?? true
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Reminders refused to update the reminder: \(error.localizedDescription)")
        }
        var output = MacOSRunOutput(
            action: .remindersComplete,
            summary: completed
                ? "Marked reminder '\(reminder.title ?? "")' as completed."
                : "Reopened reminder '\(reminder.title ?? "")'."
        )
        output.reminder = info(reminder)
        return output
    }

    static func delete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.reminderStore()
        let reminder = try resolve(input, store: store)
        let title = reminder.title ?? ""
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Reminders refused to delete the reminder: \(error.localizedDescription)")
        }
        return MacOSRunOutput(action: .remindersDelete, summary: "Deleted reminder '\(title)'.")
    }

    // MARK: - Helpers

    private static func fetch(_ predicate: NSPredicate, store: EKEventStore) async -> [Snapshot] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    Snapshot(
                        info: info(reminder),
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        created: reminder.creationDate,
                        completion: reminder.completionDate
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    private static func resolve(_ input: MacOSRunInput, store: EKEventStore) throws -> EKReminder {
        let identifier = try input.require(input.reminder_id, "reminder_id")
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw MacOSControlError.notFound("No reminder has id '\(identifier)'. Use action=list to look it up.")
        }
        return reminder
    }

    private static func apply(_ input: MacOSRunInput, to reminder: EKReminder) throws {
        if let notes = input.notes {
            reminder.notes = notes.isEmpty ? nil : notes
        }
        if let rawURL = input.url {
            if rawURL.isEmpty {
                reminder.url = nil
            } else if let url = URL(string: rawURL) {
                reminder.url = url
            } else {
                throw MacOSControlError.invalidArgument("url", "'\(rawURL)' is not a valid URL.")
            }
        }
        if let priority = input.priority {
            reminder.priority = try priorityValue(priority)
        }
        if input.clear_due == true {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach(reminder.removeAlarm)
        } else if let due = try MacOSDate.parse(input.due, argument: "due", action: input.action) {
            let hasTime = !MacOSDate.isDateOnly(input.due)
            var components = Calendar.current.dateComponents(
                hasTime ? [.year, .month, .day, .hour, .minute, .second] : [.year, .month, .day],
                from: due
            )
            components.calendar = Calendar.current
            if hasTime {
                components.timeZone = TimeZone.current
            }
            reminder.dueDateComponents = components
            // Alarms follow the due time: a dated reminder alerts at its due
            // time unless alarm_minutes says otherwise.
            if !hasTime, let minutes = input.alarm_minutes, !minutes.isEmpty {
                throw MacOSControlError.invalidArgument("alarm_minutes", "alerts need a due time; pass due with a time of day.")
            }
            try replaceAlarms(of: reminder, due: hasTime ? due : nil, minutes: hasTime ? (input.alarm_minutes ?? [0]) : [])
        } else if let minutes = input.alarm_minutes {
            guard let dueComponents = reminder.dueDateComponents, dueComponents.hour != nil,
                  let due = Calendar.current.date(from: dueComponents) else {
                throw MacOSControlError.invalidArgument("alarm_minutes", "alerts need a due time; pass due with a time of day.")
            }
            try replaceAlarms(of: reminder, due: due, minutes: minutes)
        }
        if let recurrence = input.recurrence {
            if recurrence.lowercased() == "none" {
                reminder.recurrenceRules = nil
            } else if let rule = try EventKitSupport.recurrenceRule(from: input) {
                reminder.recurrenceRules = [rule]
            }
        }
    }

    /// Validates every offset before touching the reminder, then replaces its
    /// alarms with absolute alerts relative to `due`.
    private static func replaceAlarms(of reminder: EKReminder, due: Date?, minutes: [Int]) throws {
        for value in minutes {
            try EventKitSupport.validateAlarmMinutes(value, reference: "due time")
        }
        reminder.alarms?.forEach(reminder.removeAlarm)
        guard let due else { return }
        for value in minutes {
            reminder.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(TimeInterval(-value * 60))))
        }
    }

    static func priorityValue(_ raw: String) throws -> Int {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "none", "0": return 0
        case "high", "1": return 1
        case "medium", "5": return 5
        case "low", "9": return 9
        default:
            if let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), (0...9).contains(value) {
                return value
            }
            throw MacOSControlError.invalidArgument("priority", "use none, low, medium, high, or an integer from 0 (none) to 9 (lowest).")
        }
    }

    static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        default: return "low"
        }
    }

    static func info(_ reminder: EKReminder) -> ReminderInfo {
        let dueComponents = reminder.dueDateComponents
        let hasTime = dueComponents?.hour != nil
        let dueDate = dueComponents.flatMap { Calendar.current.date(from: $0) }
        let alarms = reminder.alarms?.compactMap { alarm -> String? in
            if let absolute = alarm.absoluteDate {
                return MacOSDate.format(absolute)
            }
            return "\(Int((-alarm.relativeOffset / 60).rounded())) minutes before"
        }
        return ReminderInfo(
            id: reminder.calendarItemIdentifier,
            list: reminder.calendar.title,
            list_id: reminder.calendar.calendarIdentifier,
            title: reminder.title,
            notes: reminder.notes,
            completed: reminder.isCompleted,
            completion_date: MacOSDate.format(reminder.completionDate),
            due: hasTime ? MacOSDate.format(dueDate) : MacOSDate.formatDay(dueDate),
            due_has_time: hasTime,
            priority: priorityLabel(reminder.priority),
            priority_value: reminder.priority,
            alarms: (alarms?.isEmpty ?? true) ? nil : alarms,
            url: reminder.url?.absoluteString,
            is_recurring: reminder.hasRecurrenceRules,
            created: MacOSDate.format(reminder.creationDate),
            modified: MacOSDate.format(reminder.lastModifiedDate)
        )
    }
}
