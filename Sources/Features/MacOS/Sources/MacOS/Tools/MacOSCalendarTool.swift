import FeatureKit
import Foundation
import ToolCore

struct MacOSCalendarTool: FeatureTool {
    static let app = MacOSApp.calendar
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Calendar (EventKit): list calendars, list events in a date range with recurrences expanded, create, update, and delete events (single occurrences or whole series). Needs the Calendar privacy grant: check it with macos.permissions first."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "list: calendars. events: events in [start, end] (default: the next 7 days). create_event / update_event / delete_event: manage one event; recurring events are addressed by event_id plus occurrence_start and span.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum events returned by events (default 100)." },
            "query": { "type": "string", "description": "events: substring filter on title, location, and notes." },
            "start": { "type": "string", "description": "ISO 8601 date or date-time (local time zone unless an offset is given; also now/today/tomorrow). Range start for events (default today 00:00); event start for create_event and update_event." },
            "end": { "type": "string", "description": "ISO 8601 date or date-time. Range end for events (default start + 7 days; a plain date is inclusive); event end for create_event (default start + 1 hour) and update_event." },
            "calendar": { "type": "string", "description": "Calendar title or id (see list). Filters events; target calendar for create_event and update_event (default: the user's default calendar)." },
            "event_id": { "type": "string", "description": "Event id from events, for update_event and delete_event." },
            "occurrence_start": { "type": "string", "description": "ISO start of the specific occurrence of a recurring event to update or delete; omit for non-recurring events." },
            "span": { "type": "string", "enum": ["this", "future"], "description": "Recurring events: 'this' (default) changes only the selected occurrence, 'future' changes it and all later ones." },
            "title": { "type": "string", "description": "Event title for create_event and update_event." },
            "all_day": { "type": "boolean", "description": "All-day event flag; defaults to true when start is a plain date." },
            "location": { "type": "string", "description": "Event location (empty string clears it)." },
            "notes": { "type": "string", "description": "Event notes (empty string clears them)." },
            "url": { "type": "string", "description": "URL attached to the event (empty string clears it)." },
            "alarm_minutes": { "type": "array", "items": { "type": "integer", "minimum": 0 }, "description": "Alerts in minutes before the event start (0 = at the start)." },
            "recurrence": { "type": "string", "enum": ["none", "daily", "weekly", "monthly", "yearly"], "description": "Repeat rule; 'none' removes it." },
            "recurrence_interval": { "type": "integer", "minimum": 1, "maximum": 365, "description": "Repeat every N units of the recurrence (default 1)." },
            "recurrence_end": { "type": "string", "description": "ISO date when the repetition stops." },
            "recurrence_count": { "type": "integer", "minimum": 1, "description": "Number of occurrences, as an alternative to recurrence_end." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "calendars": { "type": "array", "items": { "$ref": "#/$defs/calendar" } },
            "events": { "type": "array", "items": { "$ref": "#/$defs/event" } },
            "event": { "$ref": "#/$defs/event" }
        """#,
        defs: ["calendar", "event"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Calendar",
        subjectArguments: ["query", "title", "event_id", "calendar", "start"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
