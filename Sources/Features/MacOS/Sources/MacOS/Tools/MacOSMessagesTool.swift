import FeatureKit
import Foundation
import ToolCore

struct MacOSMessagesTool: FeatureTool {
    static let app = MacOSApp.messages
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Messages app (iMessage/SMS): list conversations, read the history of a conversation, and send a text. Reading the history needs Full Disk Access for the application hosting ZenCODE (check with macos.permissions); sending goes through Apple Events and asks for Automation consent on first use."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "chats: recent conversations. read: the most recent messages of a conversation (chat_id or handle), returned in chronological order. send: a text to a conversation (chat_id) or to a handle/contact (to).",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum results: chats (default 50) and read (default 30)." },
            "query": { "type": "string", "description": "chats: substring filter on handle and name. read: substring filter on the text." },
            "since": { "type": "string", "description": "read: ISO 8601 lower bound on the message date." },
            "chat_id": { "type": "string", "description": "Conversation id from chats, for read and send." },
            "handle": { "type": "string", "description": "Phone number or email of the other party, for read and send." },
            "to": { "type": "array", "items": { "type": "string" }, "description": "send: one handle (phone number in international format or iMessage email) or an exact contact name." },
            "text": { "type": "string", "description": "send: the message text." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "chats": { "type": "array", "items": { "$ref": "#/$defs/chat" } },
            "texts": { "type": "array", "items": { "$ref": "#/$defs/text_message" } }
        """#,
        defs: ["chat", "text_message"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Messages",
        subjectArguments: ["query", "text", "chat_id", "handle", "to"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
