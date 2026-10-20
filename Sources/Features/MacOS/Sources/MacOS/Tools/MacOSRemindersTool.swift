import FeatureKit
import Foundation
import ToolCore

struct MacOSRemindersTool: FeatureTool {
    static let app = MacOSApp.reminders
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Reminders (EventKit): reminder lists, list and search reminders by status and due date, create, update, complete/reopen, and delete reminders with due dates, alerts, priorities, and repeat rules. Needs the Reminders privacy grant: check it with macos.permissions first."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "lists: reminder lists. list: reminders (default: incomplete ones, across all lists, including reminders without a due date; since/until restrict to reminders with a due date in range). create / update / complete / delete: manage one reminder by reminder_id.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum reminders returned by list (default 100)." },
            "query": { "type": "string", "description": "list: substring filter on title and notes." },
            "since": { "type": "string", "description": "list: ISO 8601 (or today/tomorrow) lower bound on the due date. Omit it to list reminders regardless of due date: when since or until is set, reminders without a due date are excluded unless include_undated is true." },
            "until": { "type": "string", "description": "list: ISO 8601 (or today/tomorrow) upper bound on the due date (a plain date includes the whole day). Same undated rule as since." },
            "include_undated": { "type": "boolean", "description": "list: when since/until are set, also return reminders without a due date (default false). Ignored without date bounds, where undated reminders are always included." },
            "status": { "type": "string", "enum": ["incomplete", "completed", "all"], "description": "list filter (default incomplete)." },
            "list": { "type": "string", "description": "Reminder list title or id (see lists). Filters list; target list for create and update (default: the default list)." },
            "reminder_id": { "type": "string", "description": "Reminder id from list, for update, complete, and delete." },
            "title": { "type": "string", "description": "Reminder title for create and update." },
            "notes": { "type": "string", "description": "Reminder notes (empty string clears them)." },
            "url": { "type": "string", "description": "URL attached to the reminder (empty string clears it)." },
            "due": { "type": "string", "description": "Due date (plain date) or date-time (local time zone unless an offset is given; also now/today/tomorrow) for create and update." },
            "clear_due": { "type": "boolean", "description": "update: remove the due date and its alerts." },
            "priority": { "type": "string", "description": "Priority: none, low, medium, high (or 0-9, 1 = highest)." },
            "completed": { "type": "boolean", "description": "complete: true (default) completes the reminder, false reopens it; also accepted by update." },
            "alarm_minutes": { "type": "array", "items": { "type": "integer", "minimum": 0 }, "description": "Alerts in minutes before the due time (0 = at the due time). A reminder with a due time gets an alert at that time unless specified." },
            "recurrence": { "type": "string", "enum": ["none", "daily", "weekly", "monthly", "yearly"], "description": "Repeat rule; 'none' removes it." },
            "recurrence_interval": { "type": "integer", "minimum": 1, "maximum": 365, "description": "Repeat every N units of the recurrence (default 1)." },
            "recurrence_end": { "type": "string", "description": "ISO date when the repetition stops." },
            "recurrence_count": { "type": "integer", "minimum": 1, "description": "Number of occurrences, as an alternative to recurrence_end." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "reminder_lists": { "type": "array", "items": { "$ref": "#/$defs/reminder_list" } },
            "reminders": { "type": "array", "items": { "$ref": "#/$defs/reminder" } },
            "reminder": { "$ref": "#/$defs/reminder" }
        """#,
        defs: ["reminder_list", "reminder"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Reminders",
        subjectArguments: ["query", "title", "reminder_id", "list"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
