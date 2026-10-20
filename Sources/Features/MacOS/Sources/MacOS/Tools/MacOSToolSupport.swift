import FeatureKit
import Foundation
import ToolCore

/// Shared building blocks of the `macos.<app>` tools: every tool decodes the
/// same `MacOSRunInput`, exposes an `action` enum made of the short action
/// names of its app, and dispatches to `MacOSController`.
enum MacOSToolSupport {
    static let dateConventions = "Dates are ISO 8601; values without a UTC offset are in the user's local time zone and outputs carry the local offset. Ids returned by list/search actions are the handles for get/update/delete actions."

    static let noCodeExecution = "The tool never runs caller-supplied AppleScript, JavaScript, or shell code."

    static func run(_ app: MacOSApp, _ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSController.execute(app, input, context: context)
    }

    /// Appends the shared conventions and the confirmation contract of `app`
    /// to a tool description.
    static func description(_ app: MacOSApp, _ text: String) -> String {
        var parts = [text, dateConventions]
        let confirmed = app.confirmedActionNames
        if !confirmed.isEmpty {
            parts.append(
                "Destructive or outbound actions (\(confirmed.joined(separator: ", "))) require confirm=true: ask the user for explicit approval before setting it."
            )
        }
        parts.append(noCodeExecution)
        return parts.joined(separator: " ")
    }

    /// Builds the input schema: `action` enum plus `confirm` (when the app has
    /// confirmable actions), followed by the app-specific `properties` (JSON
    /// object members without the surrounding braces).
    static func inputSchema(_ app: MacOSApp, actionDescription: String, properties: String) -> String {
        let actionEnum = app.actionNames.map { "\"\($0)\"" }.joined(separator: ", ")
        var members: [String] = [
            "\"action\": { \"type\": \"string\", \"enum\": [\(actionEnum)], \"description\": \(jsonString(actionDescription)) }"
        ]
        let confirmed = app.confirmedActionNames
        if !confirmed.isEmpty {
            let text = "Must be true for \(confirmed.joined(separator: ", ")). Set it only after the user explicitly approved that exact operation."
            members.append("\"confirm\": { \"type\": \"boolean\", \"description\": \(jsonString(text)) }")
        }
        let trimmedProperties = properties.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProperties.isEmpty {
            members.append(trimmedProperties)
        }
        return """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["action"],
          "properties": {
            \(members.joined(separator: ",\n    "))
          }
        }
        """
    }

    /// Builds the output schema: the common envelope plus the app-specific
    /// result `properties` and the `$defs` they reference (dependencies are
    /// added automatically).
    static func outputSchema(properties: String, defs: [String]) -> String {
        var members: [String] = [
            "\"ok\": { \"type\": \"boolean\", \"const\": true }",
            "\"action\": { \"type\": \"string\" }",
            "\"summary\": { \"type\": \"string\" }",
            "\"hint\": { \"type\": \"string\" }",
            "\"count\": { \"type\": \"integer\", \"minimum\": 0 }"
        ]
        let trimmedProperties = properties.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProperties.isEmpty {
            members.append(trimmedProperties)
        }
        let resolvedDefs = MacOSOutputDefs.resolve(defs)
        var defsBlock = ""
        if !resolvedDefs.isEmpty {
            let entries = resolvedDefs.map { "\"\($0)\": \(MacOSOutputDefs.definitions[$0] ?? "{}")" }
            defsBlock = ",\n  \"$defs\": {\n    " + entries.joined(separator: ",\n    ") + "\n  }"
        }
        return """
        {
          "type": "object",
          "required": ["ok", "action", "summary"],
          "properties": {
            \(members.joined(separator: ",\n    "))
          }\(defsBlock)
        }
        """
    }

    static func presentation(title: String, subjectArguments: [String]) -> ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: title,
            action: "Assist",
            kind: .manage,
            target: .argument(["action"], format: .text),
            metadata: [
                ToolPresentationMetadataDefinition(
                    label: "subject",
                    value: .argument(subjectArguments, format: .text)
                ),
            ],
            sections: [.parameters()],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let encoded = String(decoding: data, as: UTF8.self)
        // JSONSerialization wraps the single string in an array: strip the brackets.
        return String(encoded.dropFirst().dropLast())
    }
}

/// JSON Schema `$defs` of the result records, shared across the tools.
enum MacOSOutputDefs {
    /// Definitions that another definition references.
    private static let dependencies: [String: [String]] = [
        "event": ["participant"],
        "contact": ["labeled_value"]
    ]

    static func resolve(_ names: [String]) -> [String] {
        var ordered: [String] = []
        func add(_ name: String) {
            guard !ordered.contains(name) else { return }
            for dependency in dependencies[name] ?? [] { add(dependency) }
            ordered.append(name)
        }
        names.forEach(add)
        return ordered
    }

    static let definitions: [String: String] = [
        "labeled_value": #"{ "type": "object", "required": ["value"], "properties": { "label": { "type": "string" }, "value": { "type": "string" } } }"#,
        "participant": #"{ "type": "object", "required": ["status", "is_current_user"], "properties": { "name": { "type": "string" }, "email": { "type": "string" }, "status": { "type": "string" }, "is_current_user": { "type": "boolean" } } }"#,
        "calendar": #"""
        {
              "type": "object", "required": ["id", "title", "type", "allows_modifications", "is_subscribed", "is_default"],
              "properties": { "id": { "type": "string" }, "title": { "type": "string" }, "type": { "type": "string" }, "source": { "type": "string" }, "color": { "type": "string" }, "allows_modifications": { "type": "boolean" }, "is_subscribed": { "type": "boolean" }, "is_default": { "type": "boolean" } }
            }
        """#,
        "event": #"""
        {
              "type": "object", "required": ["id", "calendar", "calendar_id", "all_day", "status", "availability", "is_recurring", "is_detached_occurrence"],
              "properties": {
                "id": { "type": "string" }, "calendar": { "type": "string" }, "calendar_id": { "type": "string" }, "title": { "type": "string" },
                "start": { "type": "string" }, "end": { "type": "string" }, "all_day": { "type": "boolean" }, "location": { "type": "string" },
                "notes": { "type": "string" }, "url": { "type": "string" }, "status": { "type": "string" }, "availability": { "type": "string" },
                "organizer": { "$ref": "#/$defs/participant" }, "attendees": { "type": "array", "items": { "$ref": "#/$defs/participant" } },
                "is_recurring": { "type": "boolean" }, "recurrence": { "type": "string" }, "is_detached_occurrence": { "type": "boolean" },
                "alarm_minutes_before": { "type": "array", "items": { "type": "integer" } }, "time_zone": { "type": "string" },
                "created": { "type": "string" }, "modified": { "type": "string" }
              }
            }
        """#,
        "reminder_list": #"""
        {
              "type": "object", "required": ["id", "title", "allows_modifications", "is_default"],
              "properties": { "id": { "type": "string" }, "title": { "type": "string" }, "source": { "type": "string" }, "color": { "type": "string" }, "allows_modifications": { "type": "boolean" }, "is_default": { "type": "boolean" } }
            }
        """#,
        "reminder": #"""
        {
              "type": "object", "required": ["id", "list", "list_id", "completed", "due_has_time", "priority", "priority_value", "is_recurring"],
              "properties": {
                "id": { "type": "string" }, "list": { "type": "string" }, "list_id": { "type": "string" }, "title": { "type": "string" }, "notes": { "type": "string" },
                "completed": { "type": "boolean" }, "completion_date": { "type": "string" }, "due": { "type": "string" }, "due_has_time": { "type": "boolean" },
                "priority": { "type": "string" }, "priority_value": { "type": "integer" }, "alarms": { "type": "array", "items": { "type": "string" } },
                "url": { "type": "string" }, "is_recurring": { "type": "boolean" }, "created": { "type": "string" }, "modified": { "type": "string" }
              }
            }
        """#,
        "contact": #"""
        {
              "type": "object", "required": ["id", "name", "is_company", "emails", "phones", "addresses", "urls", "social_profiles", "has_image"],
              "properties": {
                "id": { "type": "string" }, "name": { "type": "string" }, "given_name": { "type": "string" }, "family_name": { "type": "string" },
                "middle_name": { "type": "string" }, "nickname": { "type": "string" }, "organization": { "type": "string" }, "job_title": { "type": "string" },
                "department": { "type": "string" }, "is_company": { "type": "boolean" },
                "emails": { "type": "array", "items": { "$ref": "#/$defs/labeled_value" } }, "phones": { "type": "array", "items": { "$ref": "#/$defs/labeled_value" } },
                "addresses": { "type": "array", "items": { "type": "object", "properties": { "label": { "type": "string" }, "street": { "type": "string" }, "city": { "type": "string" }, "state": { "type": "string" }, "postal_code": { "type": "string" }, "country": { "type": "string" } } } },
                "urls": { "type": "array", "items": { "$ref": "#/$defs/labeled_value" } },
                "social_profiles": { "type": "array", "items": { "type": "object", "properties": { "service": { "type": "string" }, "username": { "type": "string" }, "url": { "type": "string" } } } },
                "birthday": { "type": "string" }, "has_image": { "type": "boolean" }
              }
            }
        """#,
        "mail_account": #"""
        {
              "type": "object", "required": ["name", "email_addresses", "mailboxes"],
              "properties": {
                "name": { "type": "string" }, "id": { "type": "string" }, "type": { "type": "string" }, "email_addresses": { "type": "array", "items": { "type": "string" } },
                "full_name": { "type": "string" }, "enabled": { "type": "boolean" },
                "mailboxes": { "type": "array", "items": { "type": "object", "required": ["name"], "properties": { "name": { "type": "string" }, "unread_count": { "type": "integer" } } } }
              }
            }
        """#,
        "mail_message": #"""
        {
              "type": "object", "required": ["id"],
              "properties": {
                "id": { "type": "integer" }, "account": { "type": "string" }, "mailbox": { "type": "string" }, "subject": { "type": "string" }, "sender": { "type": "string" },
                "date_received": { "type": "string" }, "date_sent": { "type": "string" }, "read": { "type": "boolean" }, "flagged": { "type": "boolean" }, "message_id": { "type": "string" }
              }
            }
        """#,
        "mail_message_detail": #"""
        {
              "type": "object", "required": ["id", "to", "cc", "content", "content_truncated", "attachments"],
              "properties": {
                "id": { "type": "integer" }, "account": { "type": "string" }, "mailbox": { "type": "string" }, "subject": { "type": "string" }, "sender": { "type": "string" },
                "reply_to": { "type": "string" }, "date_received": { "type": "string" }, "date_sent": { "type": "string" }, "read": { "type": "boolean" }, "flagged": { "type": "boolean" },
                "to": { "type": "array", "items": { "type": "string" } }, "cc": { "type": "array", "items": { "type": "string" } }, "message_id": { "type": "string" },
                "content": { "type": "string" }, "content_truncated": { "type": "boolean" },
                "attachments": { "type": "array", "items": { "type": "object", "properties": { "name": { "type": "string" }, "mime_type": { "type": "string" }, "size": { "type": "integer" }, "downloaded": { "type": "boolean" } } } }
              }
            }
        """#,
        "chat": #"""
        {
              "type": "object", "required": ["id", "participants"],
              "properties": { "id": { "type": "string" }, "name": { "type": "string" }, "participants": { "type": "array", "items": { "type": "object", "properties": { "handle": { "type": "string" }, "name": { "type": "string" } } } } }
            }
        """#,
        "text_message": #"""
        {
              "type": "object", "required": ["id", "sender", "is_from_me", "has_attachments"],
              "properties": {
                "id": { "type": "integer" }, "chat_identifier": { "type": "string" }, "chat_name": { "type": "string" }, "sender": { "type": "string" }, "is_from_me": { "type": "boolean" },
                "date": { "type": "string" }, "text": { "type": "string" }, "service": { "type": "string" }, "has_attachments": { "type": "boolean" }, "is_read": { "type": "boolean" }
              }
            }
        """#,
        "album": #"{ "type": "object", "required": ["id"], "properties": { "id": { "type": "string" }, "name": { "type": "string" }, "item_count": { "type": "integer" } } }"#,
        "media_item": #"""
        {
              "type": "object", "required": ["id"],
              "properties": {
                "id": { "type": "string" }, "filename": { "type": "string" }, "title": { "type": "string" }, "description": { "type": "string" }, "date": { "type": "string" },
                "favorite": { "type": "boolean" }, "width": { "type": "integer" }, "height": { "type": "integer" }, "keywords": { "type": "array", "items": { "type": "string" } },
                "latitude": { "type": "number" }, "longitude": { "type": "number" }, "altitude": { "type": "number" }
              }
            }
        """#,
        "note_folder": #"{ "type": "object", "required": ["account", "name", "id"], "properties": { "account": { "type": "string" }, "name": { "type": "string" }, "id": { "type": "string" }, "note_count": { "type": "integer" } } }"#,
        "note": #"""
        {
              "type": "object", "required": ["id"],
              "properties": {
                "id": { "type": "string" }, "name": { "type": "string" }, "folder": { "type": "string" }, "account": { "type": "string" }, "created": { "type": "string" }, "modified": { "type": "string" },
                "snippet": { "type": "string" }, "password_protected": { "type": "boolean" }, "shared": { "type": "boolean" }
              }
            }
        """#,
        "note_detail": #"""
        {
              "type": "object", "required": ["id", "format", "content", "content_truncated"],
              "properties": {
                "id": { "type": "string" }, "name": { "type": "string" }, "folder": { "type": "string" }, "account": { "type": "string" }, "created": { "type": "string" }, "modified": { "type": "string" },
                "format": { "type": "string" }, "content": { "type": "string" }, "content_truncated": { "type": "boolean" }, "password_protected": { "type": "boolean" }, "shared": { "type": "boolean" }
              }
            }
        """#,
        "permissions": #"""
        {
              "type": "object",
              "required": ["calendar", "reminders", "contacts", "messages_database", "automation"],
              "properties": {
                "calendar": { "type": "string" }, "reminders": { "type": "string" }, "contacts": { "type": "string" },
                "messages_database": { "type": "string" }, "automation": { "type": "string" }
              }
            }
        """#
    ]
}
