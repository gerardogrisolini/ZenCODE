import FeatureKit
import Foundation
import ToolCore

struct MacOSContactsTool: FeatureTool {
    static let app = MacOSApp.contacts
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Contacts: search by name, email address, or phone number; get a full contact card; create, update, and delete contacts (names, organization, emails, phones, URLs, postal addresses, birthday). Needs the Contacts privacy grant: check it with macos.permissions first."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "search: find contacts by query. get / update / delete: one contact by contact_id. create: a new person (given_name/family_name) or company (organization only). List arguments of update replace the existing list.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum contacts returned by search (default 25)." },
            "query": { "type": "string", "description": "search: a name, an email address, or a phone number." },
            "contact_id": { "type": "string", "description": "Contact id from search, for get, update, and delete." },
            "given_name": { "type": "string", "description": "First name." },
            "family_name": { "type": "string", "description": "Last name." },
            "middle_name": { "type": "string" },
            "organization": { "type": "string", "description": "Company; a contact with only an organization is stored as a company." },
            "job_title": { "type": "string" },
            "nickname": { "type": "string" },
            "emails": { "type": "array", "items": { "type": "object", "required": ["value"], "properties": { "label": { "type": "string" }, "value": { "type": "string" } } }, "description": "Email addresses as {label, value} (labels: home, work, icloud, other, or custom). Replaces the existing list." },
            "phones": { "type": "array", "items": { "type": "object", "required": ["value"], "properties": { "label": { "type": "string" }, "value": { "type": "string" } } }, "description": "Phone numbers as {label, value} (labels: mobile, iphone, home, work, main, other, or custom). Replaces the existing list." },
            "urls": { "type": "array", "items": { "type": "object", "required": ["value"], "properties": { "label": { "type": "string" }, "value": { "type": "string" } } }, "description": "URLs as {label, value}. Replaces the existing list." },
            "addresses": { "type": "array", "items": { "type": "object", "properties": { "label": { "type": "string" }, "street": { "type": "string" }, "city": { "type": "string" }, "state": { "type": "string" }, "postal_code": { "type": "string" }, "country": { "type": "string" } } }, "description": "Postal addresses. Replaces the existing list." },
            "birthday": { "type": "string", "description": "Birthday as yyyy-MM-dd or --MM-dd (empty string clears it)." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "contacts": { "type": "array", "items": { "$ref": "#/$defs/contact" } },
            "contact": { "$ref": "#/$defs/contact" }
        """#,
        defs: ["contact"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Contacts",
        subjectArguments: ["query", "contact_id", "given_name", "family_name", "organization"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
