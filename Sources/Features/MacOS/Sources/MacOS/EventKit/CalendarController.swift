import EventKit
import Foundation

enum CalendarController {
    static func list(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.eventStore()
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        let calendars = store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    type: EventKitSupport.typeLabel(calendar.type),
                    source: calendar.source?.title,
                    color: EventKitSupport.hexColor(calendar.cgColor),
                    allows_modifications: calendar.allowsContentModifications,
                    is_subscribed: calendar.isSubscribed,
                    is_default: calendar.calendarIdentifier == defaultID
                )
            }
        var output = MacOSRunOutput(action: .calendarList, summary: "\(calendars.count) calendars.")
        output.calendars = calendars
        output.count = calendars.count
        return output
    }

    static func events(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.eventStore()
        let now = Date()
        let start = try MacOSDate.parse(input.start ?? input.since, argument: "start", action: input.action)
            ?? Calendar.current.startOfDay(for: now)
        var end = try MacOSDate.parse(input.end ?? input.until, argument: "end", action: input.action)
            ?? Calendar.current.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 86_400)
        if MacOSDate.isDateOnly(input.end ?? input.until) {
            // An inclusive end day: extend to the end of that day.
            end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
        }
        guard end > start else {
            throw MacOSControlError.invalidArgument("end", "must be later than start.")
        }
        guard end.timeIntervalSince(start) <= 366 * 86_400 * 4 else {
            throw MacOSControlError.invalidArgument("end", "the range must not exceed four years.")
        }

        var calendars: [EKCalendar]?
        if let selector = input.calendar {
            calendars = [try EventKitSupport.calendar(named: selector, in: store, entity: .event)]
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var matched = store.events(matching: predicate)
        if let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            matched = matched.filter { event in
                [event.title, event.location, event.notes].contains { field in
                    field?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        matched.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        let limit = input.boundedLimit(default: 100, maximum: 500)
        let total = matched.count
        let notesLimit = input.boundedMaxChars(default: 500, maximum: 20_000)
        let events = matched.prefix(limit).map { info($0, notesLimit: notesLimit) }
        var output = MacOSRunOutput(
            action: .calendarEvents,
            summary: "\(total) events between \(MacOSDate.format(start) ?? "") and \(MacOSDate.format(end) ?? "")"
                + (total > limit ? " (showing \(limit))." : ".")
        )
        output.events = events
        output.count = total
        if total > limit {
            output.hint = "Narrow the range, pick a calendar, or raise limit to see every event."
        }
        return output
    }

    static func create(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.eventStore()
        let title = try input.require(input.title, "title")
        guard let start = try MacOSDate.parse(input.start, argument: "start", action: input.action) else {
            throw MacOSControlError.missingArgument("start", input.action)
        }
        let allDay = input.all_day ?? MacOSDate.isDateOnly(input.start)
        var end = try MacOSDate.parse(input.end, argument: "end", action: input.action)
        if end == nil {
            end = allDay
                ? start
                : start.addingTimeInterval(3_600)
        } else if allDay, MacOSDate.isDateOnly(input.end), let resolved = end, resolved > start {
            // An inclusive end day for multi-day all-day events.
            end = Calendar.current.date(byAdding: .second, value: -1, to: Calendar.current.date(byAdding: .day, value: 1, to: resolved) ?? resolved)
        }
        guard let end, end >= start else {
            throw MacOSControlError.invalidArgument("end", "must not be earlier than start.")
        }

        let event = EKEvent(eventStore: store)
        if let selector = input.calendar {
            event.calendar = try EventKitSupport.calendar(named: selector, in: store, entity: .event)
        } else if let defaultCalendar = store.defaultCalendarForNewEvents {
            event.calendar = defaultCalendar
        } else {
            throw MacOSControlError.operationFailed("No default calendar is configured; pass calendar explicitly.")
        }
        guard event.calendar.allowsContentModifications else {
            throw MacOSControlError.invalidArgument("calendar", "'\(event.calendar.title)' is read-only.")
        }
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        try apply(input, to: event, isCreation: true)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Calendar refused to save the event: \(error.localizedDescription)")
        }
        var output = MacOSRunOutput(
            action: .calendarCreateEvent,
            summary: "Created event '\(title)' in '\(event.calendar.title)' starting \(MacOSDate.format(start) ?? "")."
        )
        output.event = info(event)
        return output
    }

    static func update(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.eventStore()
        let event = try resolveEvent(input, store: store)
        let span = try span(from: input)
        guard event.calendar.allowsContentModifications else {
            throw MacOSControlError.operationFailed("Event '\(event.title ?? "")' lives in the read-only calendar '\(event.calendar.title)'.")
        }
        if let title = input.title {
            event.title = title
        }
        if let start = try MacOSDate.parse(input.start, argument: "start", action: input.action) {
            let duration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            if input.end == nil {
                event.endDate = start.addingTimeInterval(max(duration, 0))
            }
        }
        if let end = try MacOSDate.parse(input.end, argument: "end", action: input.action) {
            event.endDate = end
        }
        guard event.endDate >= event.startDate else {
            throw MacOSControlError.invalidArgument("end", "must not be earlier than start.")
        }
        if let allDay = input.all_day {
            event.isAllDay = allDay
        }
        if let selector = input.calendar {
            let target = try EventKitSupport.calendar(named: selector, in: store, entity: .event)
            guard target.allowsContentModifications else {
                throw MacOSControlError.invalidArgument("calendar", "'\(target.title)' is read-only.")
            }
            event.calendar = target
        }
        try apply(input, to: event, isCreation: false)
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Calendar refused to update the event: \(error.localizedDescription)")
        }
        var output = MacOSRunOutput(
            action: .calendarUpdateEvent,
            summary: "Updated event '\(event.title ?? "")' (\(span == .futureEvents ? "this and future occurrences" : "this occurrence"))."
        )
        output.event = info(event)
        return output
    }

    static func delete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await EventKitSupport.eventStore()
        let event = try resolveEvent(input, store: store)
        let span = try span(from: input)
        let title = event.title ?? ""
        let start = MacOSDate.format(event.startDate) ?? ""
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw MacOSControlError.operationFailed("Calendar refused to delete the event: \(error.localizedDescription)")
        }
        return MacOSRunOutput(
            action: .calendarDeleteEvent,
            summary: "Deleted event '\(title)' starting \(start) (\(span == .futureEvents ? "this and future occurrences" : "this occurrence"))."
        )
    }

    // MARK: - Helpers

    private static func apply(_ input: MacOSRunInput, to event: EKEvent, isCreation: Bool) throws {
        if let location = input.location {
            event.location = location.isEmpty ? nil : location
        }
        if let notes = input.notes {
            event.notes = notes.isEmpty ? nil : notes
        }
        if let rawURL = input.url {
            if rawURL.isEmpty {
                event.url = nil
            } else if let url = URL(string: rawURL) {
                event.url = url
            } else {
                throw MacOSControlError.invalidArgument("url", "'\(rawURL)' is not a valid URL.")
            }
        }
        if let alarms = try EventKitSupport.alarms(fromMinutes: input.alarm_minutes) {
            event.alarms = alarms.isEmpty ? nil : alarms
        }
        if input.recurrence != nil {
            if let rule = try EventKitSupport.recurrenceRule(from: input) {
                event.recurrenceRules = [rule]
            } else {
                event.recurrenceRules = nil
            }
        } else if isCreation, input.recurrence_interval != nil || input.recurrence_end != nil || input.recurrence_count != nil {
            throw MacOSControlError.invalidArgument("recurrence", "recurrence_interval/recurrence_end/recurrence_count require recurrence.")
        }
    }

    private static func span(from input: MacOSRunInput) throws -> EKSpan {
        switch input.span?.lowercased() {
        case nil, "", "this", "this_event", "occurrence":
            return .thisEvent
        case "future", "future_events", "all":
            return .futureEvents
        default:
            throw MacOSControlError.invalidArgument("span", "use 'this' (default) or 'future'.")
        }
    }

    /// Finds the event addressed by `event_id`, selecting the occurrence that
    /// starts at `occurrence_start` for recurring events when it is provided.
    private static func resolveEvent(_ input: MacOSRunInput, store: EKEventStore) throws -> EKEvent {
        let identifier = try input.require(input.event_id, "event_id")
        guard let master = store.event(withIdentifier: identifier) else {
            throw MacOSControlError.notFound("No event has id '\(identifier)'. Use action=events to look it up.")
        }
        guard let occurrenceStart = try MacOSDate.parse(input.occurrence_start, argument: "occurrence_start", action: input.action) else {
            return master
        }
        let windowStart = occurrenceStart.addingTimeInterval(-86_400)
        let windowEnd = occurrenceStart.addingTimeInterval(86_400 * 2)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [master.calendar])
        let candidates = store.events(matching: predicate).filter { $0.eventIdentifier == identifier }
        if let exact = candidates.first(where: { abs($0.startDate.timeIntervalSince(occurrenceStart)) < 60 }) {
            return exact
        }
        if let sameDay = candidates.first(where: { Calendar.current.isDate($0.startDate, inSameDayAs: occurrenceStart) }) {
            return sameDay
        }
        throw MacOSControlError.notFound(
            "Event '\(master.title ?? identifier)' has no occurrence starting at \(MacOSDate.format(occurrenceStart) ?? ""). Use action=events to list its occurrences."
        )
    }

    static func info(_ event: EKEvent, notesLimit: Int? = nil) -> EventInfo {
        var notes = event.notes
        if let notesLimit, let value = notes, value.count > notesLimit {
            notes = String(value.prefix(notesLimit)) + "… [truncated; raise max_chars for the full notes]"
        }
        let status: String
        switch event.status {
        case .none: status = "none"
        case .confirmed: status = "confirmed"
        case .tentative: status = "tentative"
        case .canceled: status = "canceled"
        @unknown default: status = "unknown"
        }
        let availability: String
        switch event.availability {
        case .notSupported: availability = "not_supported"
        case .busy: availability = "busy"
        case .free: availability = "free"
        case .tentative: availability = "tentative"
        case .unavailable: availability = "unavailable"
        @unknown default: availability = "unknown"
        }
        let attendees = event.attendees?.compactMap(EventKitSupport.participant)
        return EventInfo(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendar: event.calendar.title,
            calendar_id: event.calendar.calendarIdentifier,
            title: event.title,
            start: event.isAllDay ? MacOSDate.formatDay(event.startDate) : MacOSDate.format(event.startDate),
            end: event.isAllDay ? MacOSDate.formatDay(event.endDate) : MacOSDate.format(event.endDate),
            all_day: event.isAllDay,
            location: event.location,
            notes: notes,
            url: event.url?.absoluteString,
            status: status,
            availability: availability,
            organizer: EventKitSupport.participant(event.organizer),
            attendees: (attendees?.isEmpty ?? true) ? nil : attendees,
            is_recurring: event.hasRecurrenceRules,
            recurrence: EventKitSupport.recurrenceDescription(event.recurrenceRules),
            is_detached_occurrence: event.isDetached,
            alarm_minutes_before: EventKitSupport.alarmMinutes(event.alarms),
            time_zone: event.timeZone?.identifier,
            created: MacOSDate.format(event.creationDate),
            modified: MacOSDate.format(event.lastModifiedDate)
        )
    }
}
