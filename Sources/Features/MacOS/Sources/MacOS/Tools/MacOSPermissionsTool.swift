import FeatureKit
import Foundation
import ToolCore

struct MacOSPermissionsTool: FeatureTool {
    static let app = MacOSApp.permissions
    static let name = app.toolName

    static let description = "Reports and requests the privacy access that the macos.* tools need. Call action=check before the first use of macos.calendar, macos.reminders, macos.contacts, or macos.messages: Calendar, Reminders, and Contacts need privacy grants (action=request triggers their system prompts), reading the Messages history needs Full Disk Access, and Mail, Messages, Photos, and Notes ask for Automation consent on first use. Every grant is attributed to the application hosting ZenCODE (Terminal, iTerm, Xcode, ...); a denied status must be changed in System Settings > Privacy & Security. " + MacOSToolSupport.noCodeExecution

    static let inputSchema = MacOSToolSupport.inputSchema(
        app,
        actionDescription: "check reports the current access state; request triggers the Calendar, Reminders, and Contacts permission prompts and then reports the state.",
        properties: ""
    )

    static let outputSchema: String? = MacOSToolSupport.outputSchema(
        properties: ##""permissions": { "$ref": "#/$defs/permissions" }"##,
        defs: ["permissions"]
    )

    static let presentation = MacOSToolSupport.presentation(title: "macOS permissions", subjectArguments: [])

    func run(_ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        try await MacOSToolSupport.run(Self.app, input, context: context)
    }
}
