import FeatureKit
import Foundation
import ToolCore

struct MacOSMailTool: FeatureTool {
    static let app = MacOSApp.mail
    static let name = app.toolName

    static let description = MacOSToolSupport.description(
        app,
        "Personal-assistant access to the user's Mail app: accounts and mailboxes with unread counts, list and search messages, read a message with its content and attachments, send a new message, reply, mark read/unread or flagged, move between mailboxes, and delete. Mail is driven through Apple Events: macOS asks for Automation consent on first use (see macos.permissions)."
    )

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "accounts: accounts and their mailboxes. list: messages of a mailbox (default inbox). get: one message with its content. send: a new message. reply: reply to a message. mark: read/unread or flagged. move: to another mailbox. delete: move to the trash.",
        properties: #"""
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum messages returned by list (default 25)." },
            "query": { "type": "string", "description": "list: substring filter on subject and sender." },
            "since": { "type": "string", "description": "list: ISO 8601 lower bound on the received date." },
            "until": { "type": "string", "description": "list: ISO 8601 upper bound on the received date." },
            "unread_only": { "type": "boolean", "description": "list: only unread messages." },
            "account": { "type": "string", "description": "Account name (see accounts) that scopes mailbox; also the account of the message for get, mark, move, and delete outside the inbox." },
            "mailbox": { "type": "string", "description": "Mailbox for list, get, mark, move, and delete: inbox (default), sent, drafts, trash, junk, outbox, or a mailbox name from accounts (combine with account)." },
            "message_id": { "type": "integer", "minimum": 1, "description": "Message id from list, for get, reply, mark, move, and delete. Pass mailbox and account too for messages outside the inbox." },
            "to": { "type": "array", "items": { "type": "string" }, "description": "Recipient email addresses for send." },
            "cc": { "type": "array", "items": { "type": "string" }, "description": "CC addresses for send and reply." },
            "bcc": { "type": "array", "items": { "type": "string" }, "description": "BCC addresses for send." },
            "subject": { "type": "string", "description": "Subject for send." },
            "body": { "type": "string", "description": "Plain-text body for send and reply." },
            "from": { "type": "string", "description": "Sender for send, e.g. 'Name <user@example.com>'; must belong to a configured account (default: the account's primary address)." },
            "attachments": { "type": "array", "items": { "type": "string" }, "description": "File paths to attach with send or reply." },
            "reply_all": { "type": "boolean", "description": "reply: reply to every recipient." },
            "read": { "type": "boolean", "description": "mark: mark as read (true) or unread (false)." },
            "flagged": { "type": "boolean", "description": "mark: set or clear the flag." },
            "target_mailbox": { "type": "string", "description": "Destination mailbox for move (inbox, trash, junk, or a mailbox name)." },
            "target_account": { "type": "string", "description": "Account of the destination mailbox for move (default: the message's account)." },
            "max_chars": { "type": "integer", "minimum": 1, "maximum": 200000, "description": "get: content truncation (default 20000)." }
        """#
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: #"""
        "mail_accounts": { "type": "array", "items": { "$ref": "#/$defs/mail_account" } },
            "messages": { "type": "array", "items": { "$ref": "#/$defs/mail_message" } },
            "message": { "$ref": "#/$defs/mail_message_detail" }
        """#,
        defs: ["mail_account", "mail_message", "mail_message_detail"]
    )

    static let presentation = MacOSToolSupport.presentation(
        title: "Mail",
        subjectArguments: ["query", "subject", "message_id", "mailbox", "account"]
    )

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
