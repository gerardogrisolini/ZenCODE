import FeatureKit
import Foundation
import ToolCore

struct MacOSPhotosTool: FeatureTool {
    static let app = MacOSApp.photos
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Photos library: albums, semantic search (scenes, objects, people), list items by album, capture date, or favorites, export items to a folder, import files, create albums, add items to an album, and edit title, caption, favorite flag, and keywords. Photos cannot delete media items. Photos is driven through Apple Events: macOS asks for Automation consent on first use (see macos.permissions)."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "albums: albums with item counts. search: Photos semantic search by query. list: items by album, date range, or favorites. export / import: files to and from the library. create_album / add_to_album: album management. update: title, description, favorite, or keywords of one item.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum results: search (default 25) and list (default 50)." },
            "query": { "type": "string", "description": "search: Photos semantic search text (e.g. 'beach', 'dog', a person name)." },
            "since": { "type": "string", "description": "list: ISO 8601 lower bound on the capture date." },
            "until": { "type": "string", "description": "list: ISO 8601 upper bound on the capture date." },
            "favorites_only": { "type": "boolean", "description": "list: only favorites." },
            "album": { "type": "string", "description": "Album name, folder/album path, or id for list, add_to_album, and import." },
            "media_id": { "type": "string", "description": "Media item id for update." },
            "media_ids": { "type": "array", "items": { "type": "string" }, "description": "Media item ids for export and add_to_album (max 100 per call)." },
            "directory": { "type": "string", "description": "Export folder for export (default: ~/Downloads/ZenCODE Photos/<timestamp>)." },
            "use_originals": { "type": "boolean", "description": "export: export unmodified originals instead of the current versions." },
            "paths": { "type": "array", "items": { "type": "string" }, "description": "Image or video files to import." },
            "skip_duplicates": { "type": "boolean", "description": "import: skip the duplicate check." },
            "name": { "type": "string", "description": "Album name for create_album." },
            "title": { "type": "string", "description": "update: title." },
            "description": { "type": "string", "description": "update: caption." },
            "favorite": { "type": "boolean", "description": "update: mark or unmark as favorite." },
            "keywords": { "type": "array", "items": { "type": "string" }, "description": "update: replace the keywords." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "albums": { "type": "array", "items": { "$ref": "#/$defs/album" } },
            "media_items": { "type": "array", "items": { "$ref": "#/$defs/media_item" } },
            "exported_files": { "type": "array", "items": { "type": "string" } }
        """#,
        defs: ["album", "media_item"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Photos",
        subjectArguments: ["query", "name", "media_id", "album", "title"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
