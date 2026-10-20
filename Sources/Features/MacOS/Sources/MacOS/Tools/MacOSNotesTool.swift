import FeatureKit
import Foundation
import ToolCore

struct MacOSNotesTool: FeatureTool {
    static let app = MacOSApp.notes
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Notes app: accounts and folders, list notes of a folder, search by title or body, read a note as text or HTML, create, update (replace or append), and delete notes. Notes is driven through Apple Events: macOS asks for Automation consent on first use (see macos.permissions)."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "folders: accounts and folders with note counts. list: notes of a folder (default: all), newest first. search: notes matching query. get: one note with its content. create: a new note. update: replace the body/title or append text. delete: move to Recently Deleted.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum results: list (default 50) and search (default 25)." },
            "query": { "type": "string", "description": "search: substring match on title and body." },
            "account": { "type": "string", "description": "Account name to scope folders (see folders)." },
            "folder": { "type": "string", "description": "Folder name, path (Parent/Child), or id for list, search, and create (default: the default folder)." },
            "note_id": { "type": "string", "description": "Note id from list or search, for get, update, and delete." },
            "title": { "type": "string", "description": "Note title for create and update." },
            "body": { "type": "string", "description": "Note content for create and update (HTML when format=html)." },
            "append": { "type": "string", "description": "update: text appended to the note instead of replacing its content." },
            "format": { "type": "string", "enum": ["text", "html"], "description": "get: output format; create and update: body format (default text)." },
            "max_chars": { "type": "integer", "minimum": 1, "maximum": 200000, "description": "get: content truncation (default 20000)." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "note_folders": { "type": "array", "items": { "$ref": "#/$defs/note_folder" } },
            "notes": { "type": "array", "items": { "$ref": "#/$defs/note" } },
            "note": { "$ref": "#/$defs/note_detail" }
        """#,
        defs: ["note_folder", "note", "note_detail"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Notes",
        subjectArguments: ["query", "title", "note_id", "folder"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
