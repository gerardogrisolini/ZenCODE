import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import FeatureKit
import Foundation
import ToolCore

private struct DesktopRunInput: Decodable, Sendable {
    let action: String

    let x: Double?
    let y: Double?
    let to_x: Double?
    let to_y: Double?
    let width: Double?
    let height: Double?
    let duration: Double?
    let interval: Double?

    let button: String?
    let click_count: Int?
    let delta_x: Double?
    let delta_y: Double?
    let scroll_unit: String?

    let text: String?
    let key: String?
    let modifiers: [String]?
    let repeat_count: Int?

    let scope: String?
    let display_index: Int?
    let window_id: UInt32?
    let include_cursor: Bool?
    let include_shadow: Bool?
    let delay: Double?
    let label: String?

    let pid: Int32?
    let bundle_id: String?
    let app_name: String?
    let app_path: String?
    let title: String?
    let window_index: Int?
    let on_screen_only: Bool?
    let limit: Int?
    let launch_if_needed: Bool?
    let force: Bool?
    let state: Bool?
    let timeout: Double?
    let target: String?
}

private struct DesktopPoint: Codable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
}

private struct DesktopRect: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
}

private struct DesktopPermissions: Codable, Sendable {
    let accessibility: Bool
    let screen_recording: Bool
    let event_posting: Bool
}

private struct DesktopDisplayInfo: Codable, Sendable {
    let capture_index: Int
    let display_id: UInt32
    let name: String
    let is_main: Bool
    let bounds: DesktopRect
    let pixel_width: Int
    let pixel_height: Int
    let scale_factor: Double
}

private struct DesktopAppInfo: Codable, Sendable {
    let pid: Int32
    let name: String?
    let bundle_id: String?
    let bundle_path: String?
    let activation_policy: String
    let is_active: Bool
    let is_hidden: Bool
    let is_terminated: Bool
}

/// A deliberately tiny, read-only process snapshot used to bypass stale
/// NSRunningApplication instances in the short-lived feature worker. It is
/// emitted only for the executable's private probe mode, never as a tool.
private struct DesktopAppProbe: Codable, Sendable {
    let exists: Bool
    let is_active: Bool
    let is_hidden: Bool
    let is_terminated: Bool
    let is_finished_launching: Bool
}

private struct DesktopWindowInfo: Codable, Sendable {
    let window_id: UInt32?
    let pid: Int32
    let app_name: String?
    let bundle_id: String?
    let title: String?
    let bounds: DesktopRect
    let layer: Int
    let is_on_screen: Bool
    let alpha: Double
    let is_focused: Bool?
    let is_minimized: Bool?
    let is_fullscreen: Bool?
}

private struct DesktopScreenshotArtifact: Codable, Sendable {
    let path: String
    let mime_type: String
    let size_bytes: Int
    let sha256: String
    let pixel_width: Int?
    let pixel_height: Int?
    let scope: String
    let display_index: Int?
    let window_id: UInt32?
    let region: DesktopRect?
    let created_at: String
}

private struct DesktopSystemInfo: Codable, Sendable {
    let os_version: String
    let architecture: String
    let process_id: Int32
    let displays: [DesktopDisplayInfo]
    let pointer: DesktopPoint
    let frontmost_app: DesktopAppInfo?
}

private struct DesktopRunOutput: Codable, Sendable, FeatureInvocationAttachmentProviding {
    let ok: Bool
    let action: String
    let summary: String
    let permissions: DesktopPermissions?
    let system: DesktopSystemInfo?
    let apps: [DesktopAppInfo]?
    let windows: [DesktopWindowInfo]?
    let app: DesktopAppInfo?
    let window: DesktopWindowInfo?
    let pointer: DesktopPoint?
    let artifact: DesktopScreenshotArtifact?
    let clipboard_text: String?
    let count: Int?
    let elapsed_ms: Int?
    let note: String?

    init(
        action: String,
        summary: String,
        permissions: DesktopPermissions? = nil,
        system: DesktopSystemInfo? = nil,
        apps: [DesktopAppInfo]? = nil,
        windows: [DesktopWindowInfo]? = nil,
        app: DesktopAppInfo? = nil,
        window: DesktopWindowInfo? = nil,
        pointer: DesktopPoint? = nil,
        artifact: DesktopScreenshotArtifact? = nil,
        clipboard_text: String? = nil,
        count: Int? = nil,
        elapsed_ms: Int? = nil,
        note: String? = nil
    ) {
        self.ok = true
        self.action = action
        self.summary = summary
        self.permissions = permissions
        self.system = system
        self.apps = apps
        self.windows = windows
        self.app = app
        self.window = window
        self.pointer = pointer
        self.artifact = artifact
        self.clipboard_text = clipboard_text
        self.count = count
        self.elapsed_ms = elapsed_ms
        self.note = note
    }

    var featureInvocationAttachments: [FeatureInvocationAttachment] {
        guard let artifact else {
            return []
        }
        return [
            FeatureInvocationAttachment(
                path: artifact.path,
                kind: .image,
                contentType: artifact.mime_type,
                originalFilename: URL(fileURLWithPath: artifact.path).lastPathComponent
            )
        ]
    }
}

private struct DesktopRunTool: FeatureTool {
    static let name = "desktop.run"
    static let description = "Controls the local macOS desktop through explicit typed actions. It can inspect permissions/system state, list apps and windows, capture PNG screenshots of a display/window/region, move/click/drag/scroll the pointer, type text or key shortcuts, launch/activate/hide/terminate apps, manipulate windows through Accessibility, use the text clipboard, open a URL/file, and wait. Call action=permissions first. Screen capture requires Screen Recording; input and window actions require Accessibility/Event Posting. Coordinates use the global Quartz desktop space with origin at the upper-left of the main display; list_windows and system_info expose usable bounds. Screenshot PNGs are attached automatically to the model's multimodal tool context. The tool never executes caller-supplied shell or AppleScript code."

    static let inputSchema = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "permissions", "request_permissions", "system_info", "list_apps", "list_windows",
            "screenshot", "move_mouse", "click", "drag", "scroll", "type_text", "press_key",
            "launch_app", "activate_app", "hide_app", "unhide_app", "terminate_app",
            "focus_window", "move_window", "resize_window", "minimize_window",
            "set_fullscreen", "close_window", "read_clipboard", "write_clipboard", "open", "wait"
          ],
          "description": "Operation to perform. request_permissions may display macOS consent prompts."
        },
        "x": { "type": "number", "description": "Global desktop X coordinate; for drag this is the optional start X." },
        "y": { "type": "number", "description": "Global desktop Y coordinate; for drag this is the optional start Y." },
        "to_x": { "type": "number", "description": "Required destination X for drag." },
        "to_y": { "type": "number", "description": "Required destination Y for drag." },
        "width": { "type": "number", "exclusiveMinimum": 0, "description": "Region or window width." },
        "height": { "type": "number", "exclusiveMinimum": 0, "description": "Region or window height." },
        "duration": { "type": "number", "minimum": 0, "maximum": 30, "description": "Movement/drag/wait duration in seconds." },
        "interval": { "type": "number", "minimum": 0, "maximum": 1, "description": "Delay between typed characters or repeated keys." },
        "button": { "type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button; defaults to left." },
        "click_count": { "type": "integer", "minimum": 1, "maximum": 3, "description": "Single, double, or triple click count." },
        "delta_x": { "type": "number", "minimum": -10000, "maximum": 10000, "description": "Horizontal scroll amount; positive scrolls left." },
        "delta_y": { "type": "number", "minimum": -10000, "maximum": 10000, "description": "Vertical scroll amount; positive scrolls up." },
        "scroll_unit": { "type": "string", "enum": ["pixel", "line"], "description": "Scroll unit; defaults to pixel." },
        "text": { "type": "string", "maxLength": 10000, "description": "Text for type_text or write_clipboard." },
        "key": { "type": "string", "description": "Physical key name for press_key, e.g. c, return, tab, escape, left, f5." },
        "modifiers": { "type": "array", "uniqueItems": true, "items": { "type": "string", "enum": ["command", "shift", "option", "control", "fn"] }, "description": "Modifiers held for press_key." },
        "repeat_count": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Number of key presses; defaults to 1." },
        "scope": { "type": "string", "enum": ["display", "window", "region"], "description": "Screenshot scope; defaults to display." },
        "display_index": { "type": "integer", "minimum": 1, "description": "1-based display index from system_info; 1 is the main display." },
        "window_id": { "type": "integer", "minimum": 1, "description": "Quartz window ID from list_windows; preferred for exact window selection." },
        "include_cursor": { "type": "boolean", "description": "Include the pointer in display/region screenshots; defaults to false." },
        "include_shadow": { "type": "boolean", "description": "Include the shadow in window screenshots; defaults to true." },
        "delay": { "type": "number", "minimum": 0, "maximum": 30, "description": "Delay before a screenshot in seconds." },
        "label": { "type": "string", "maxLength": 64, "description": "Optional safe filename label for the generated screenshot artifact." },
        "pid": { "type": "integer", "minimum": 1, "description": "Application process ID selector." },
        "bundle_id": { "type": "string", "description": "Application bundle identifier selector." },
        "app_name": { "type": "string", "description": "Application display name selector; exact matches are preferred." },
        "app_path": { "type": "string", "description": "Absolute or working-directory-relative .app path for launch_app." },
        "title": { "type": "string", "description": "Case-insensitive window-title substring selector." },
        "window_index": { "type": "integer", "minimum": 0, "maximum": 500, "description": "0-based index after filtering windows; defaults to 0." },
        "on_screen_only": { "type": "boolean", "description": "For list_windows, omit off-screen/minimized windows; defaults to false." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum list result count; defaults to 100." },
        "launch_if_needed": { "type": "boolean", "description": "For activate_app, launch a missing app first; defaults to false." },
        "force": { "type": "boolean", "description": "For terminate_app, force termination instead of requesting a clean quit." },
        "state": { "type": "boolean", "description": "Required target state for minimize_window and set_fullscreen." },
        "timeout": { "type": "number", "minimum": 0, "maximum": 30, "description": "Seconds to wait for an app to launch; defaults to 5." },
        "target": { "type": "string", "description": "URL or file path for open." }
      },
      "required": ["action"]
    }
    """#

    static let outputSchema: String? = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["ok", "action", "summary"],
      "properties": {
        "ok": { "type": "boolean", "const": true },
        "action": { "type": "string" },
        "summary": { "type": "string" },
        "permissions": {
          "type": "object",
          "required": ["accessibility", "screen_recording", "event_posting"],
          "properties": {
            "accessibility": { "type": "boolean" },
            "screen_recording": { "type": "boolean" },
            "event_posting": { "type": "boolean" }
          }
        },
        "system": {
          "type": "object",
          "required": ["os_version", "architecture", "process_id", "displays", "pointer"],
          "properties": {
            "os_version": { "type": "string" },
            "architecture": { "type": "string" },
            "process_id": { "type": "integer" },
            "displays": { "type": "array", "items": { "$ref": "#/$defs/display" } },
            "pointer": { "$ref": "#/$defs/point" },
            "frontmost_app": { "$ref": "#/$defs/app" }
          }
        },
        "apps": { "type": "array", "items": { "$ref": "#/$defs/app" } },
        "windows": { "type": "array", "items": { "$ref": "#/$defs/window" } },
        "app": { "$ref": "#/$defs/app" },
        "window": { "$ref": "#/$defs/window" },
        "pointer": { "$ref": "#/$defs/point" },
        "artifact": { "$ref": "#/$defs/artifact" },
        "clipboard_text": { "type": "string" },
        "count": { "type": "integer", "minimum": 0 },
        "elapsed_ms": { "type": "integer", "minimum": 0 },
        "note": { "type": "string" }
      },
      "$defs": {
        "point": {
          "type": "object",
          "required": ["x", "y"],
          "properties": { "x": { "type": "number" }, "y": { "type": "number" } }
        },
        "rect": {
          "type": "object",
          "required": ["x", "y", "width", "height"],
          "properties": {
            "x": { "type": "number" }, "y": { "type": "number" },
            "width": { "type": "number" }, "height": { "type": "number" }
          }
        },
        "display": {
          "type": "object",
          "required": ["capture_index", "display_id", "name", "is_main", "bounds", "pixel_width", "pixel_height", "scale_factor"],
          "properties": {
            "capture_index": { "type": "integer" }, "display_id": { "type": "integer" },
            "name": { "type": "string" }, "is_main": { "type": "boolean" },
            "bounds": { "$ref": "#/$defs/rect" }, "pixel_width": { "type": "integer" },
            "pixel_height": { "type": "integer" }, "scale_factor": { "type": "number" }
          }
        },
        "app": {
          "type": "object",
          "required": ["pid", "activation_policy", "is_active", "is_hidden", "is_terminated"],
          "properties": {
            "pid": { "type": "integer" }, "name": { "type": "string" },
            "bundle_id": { "type": "string" }, "bundle_path": { "type": "string" },
            "activation_policy": { "type": "string" }, "is_active": { "type": "boolean" },
            "is_hidden": { "type": "boolean" }, "is_terminated": { "type": "boolean" }
          }
        },
        "window": {
          "type": "object",
          "required": ["pid", "bounds", "layer", "is_on_screen", "alpha"],
          "properties": {
            "window_id": { "type": "integer" }, "pid": { "type": "integer" },
            "app_name": { "type": "string" }, "bundle_id": { "type": "string" },
            "title": { "type": "string" }, "bounds": { "$ref": "#/$defs/rect" },
            "layer": { "type": "integer" }, "is_on_screen": { "type": "boolean" },
            "alpha": { "type": "number" }, "is_focused": { "type": "boolean" },
            "is_minimized": { "type": "boolean" }, "is_fullscreen": { "type": "boolean" }
          }
        },
        "artifact": {
          "type": "object",
          "required": ["path", "mime_type", "size_bytes", "sha256", "scope", "created_at"],
          "properties": {
            "path": { "type": "string" }, "mime_type": { "const": "image/png" },
            "size_bytes": { "type": "integer" }, "sha256": { "type": "string" },
            "pixel_width": { "type": "integer" }, "pixel_height": { "type": "integer" },
            "scope": { "type": "string" }, "display_index": { "type": "integer" },
            "window_id": { "type": "integer" }, "region": { "$ref": "#/$defs/rect" },
            "created_at": { "type": "string" }
          }
        }
      }
    }
    """#

    static let presentation = ToolPresentationDefinition(
        title: "Desktop",
        action: "Control",
        kind: .manage,
        target: .argument(["action"], format: .text),
        metadata: [
            ToolPresentationMetadataDefinition(
                label: "app",
                value: .argument(["bundle_id", "app_name", "pid"], format: .text, fallback: "frontmost")
            )
        ],
        sections: [.parameters()],
        summary: ToolPresentationSummaryDefinition(
            value: .resultSummary(),
            strategy: .firstLine,
            label: "summary"
        )
    )

    func run(_ input: DesktopRunInput, context: FeatureContext) async throws -> DesktopRunOutput {
        try await DesktopController.execute(input, context: context)
    }
}

enum DesktopControlError: LocalizedError {
    case invalidAction(String)
    case missingArgument(String, String)
    case invalidArgument(String, String)
    case permissionRequired(String)
    case appNotFound
    case windowNotFound
    case processFailed(String)
    case accessibilityFailed(String, AXError)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAction(action):
            return "Unsupported desktop action: \(action)."
        case let .missingArgument(name, action):
            return "Action '\(action)' requires argument '\(name)'."
        case let .invalidArgument(name, reason):
            return "Invalid argument '\(name)': \(reason)"
        case let .permissionRequired(message):
            return message
        case .appNotFound:
            return "No matching running application was found. Use list_apps, or launch it first."
        case .windowNotFound:
            return "No matching window was found. Use list_windows and prefer window_id for exact selection."
        case let .processFailed(message):
            return message
        case let .accessibilityFailed(operation, error):
            return "Accessibility operation '\(operation)' failed with AXError \(error.rawValue)."
        case let .operationFailed(message):
            return message
        }
    }
}

enum DesktopWindowSelectionPolicy {
    static func selectedProcessID(
        requestedWindowID: UInt32?,
        matchingWindowPID: pid_t?,
        fallbackProcessID: () -> pid_t?
    ) throws -> pid_t {
        if requestedWindowID != nil {
            guard let matchingWindowPID else {
                throw DesktopControlError.windowNotFound
            }
            return matchingWindowPID
        }

        guard let fallbackPID = fallbackProcessID() else {
            throw DesktopControlError.appNotFound
        }
        return fallbackPID
    }
}

@MainActor
private enum DesktopController {
    private static let maximumTextLength = 10_000
    private static let maximumArtifacts = 50
    private static let axFullScreenAttribute = "AXFullScreen" as CFString

    static func execute(_ input: DesktopRunInput, context: FeatureContext) async throws -> DesktopRunOutput {
        let action = input.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !action.isEmpty else {
            throw DesktopControlError.invalidArgument("action", "must not be empty.")
        }

        switch action {
        case "permissions":
            return DesktopRunOutput(
                action: action,
                summary: "Read macOS automation permissions.",
                permissions: permissions()
            )

        case "request_permissions":
            requestPermissions()
            return DesktopRunOutput(
                action: action,
                summary: "Requested macOS automation permissions.",
                permissions: permissions(),
                note: "Approve any System Settings prompts. Permission changes may require relaunching ZenCODE before they become visible."
            )

        case "system_info":
            let info = DesktopSystemInfo(
                os_version: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architectureName,
                process_id: ProcessInfo.processInfo.processIdentifier,
                displays: displays(),
                pointer: pointer(),
                frontmost_app: NSWorkspace.shared.frontmostApplication.map { appInfo($0) }
            )
            return DesktopRunOutput(
                action: action,
                summary: "Read macOS system, display, pointer, and frontmost-app state.",
                permissions: permissions(),
                system: info
            )

        case "list_apps":
            let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
            let apps = runningApps(matching: input).prefix(limit).map { appInfo($0) }
            return DesktopRunOutput(
                action: action,
                summary: "Listed \(apps.count) running application(s).",
                apps: Array(apps),
                count: apps.count
            )

        case "list_windows":
            let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
            let windows = windowRecords(onScreenOnly: input.on_screen_only ?? false, matching: input)
            let result = Array(windows.prefix(limit))
            return DesktopRunOutput(
                action: action,
                summary: "Listed \(result.count) window(s) in front-to-back order.",
                windows: result,
                count: result.count,
                note: CGPreflightScreenCaptureAccess()
                    ? nil
                    : "Without Screen Recording permission, some window titles may be unavailable."
            )

        case "screenshot":
            return try await screenshot(input, context: context, action: action)

        case "move_mouse":
            try requireEventPosting()
            let destination = try requiredPoint(x: input.x, y: input.y, action: action)
            try validateDesktopPoint(destination, argument: "x/y")
            try movePointer(to: destination, duration: try movementDuration(input.duration))
            return DesktopRunOutput(
                action: action,
                summary: "Moved the pointer to (\(format(destination.x)), \(format(destination.y))).",
                pointer: pointer()
            )

        case "click":
            try requireEventPosting()
            if input.x != nil || input.y != nil {
                let destination = try requiredPoint(x: input.x, y: input.y, action: action)
                try validateDesktopPoint(destination, argument: "x/y")
                try movePointer(to: destination, duration: try movementDuration(input.duration))
            }
            let mouseButton = try parseMouseButton(input.button)
            let clickCount = try boundedInteger(input.click_count ?? 1, name: "click_count", range: 1...3)
            try click(button: mouseButton, count: clickCount)
            let location = pointer()
            return DesktopRunOutput(
                action: action,
                summary: "Performed \(clickCount) \(mouseButton.name) click(s) at (\(format(location.x)), \(format(location.y))).",
                pointer: location,
                count: clickCount
            )

        case "drag":
            try requireEventPosting()
            let start: CGPoint
            if input.x != nil || input.y != nil {
                start = try requiredPoint(x: input.x, y: input.y, action: action)
            } else {
                start = currentPointerLocation()
            }
            let destination = try requiredPoint(x: input.to_x, y: input.to_y, action: action, xName: "to_x", yName: "to_y")
            try validateDesktopPoint(start, argument: "x/y")
            try validateDesktopPoint(destination, argument: "to_x/to_y")
            let mouseButton = try parseMouseButton(input.button)
            try dragPointer(from: start, to: destination, duration: try movementDuration(input.duration), button: mouseButton)
            return DesktopRunOutput(
                action: action,
                summary: "Dragged the \(mouseButton.name) button to (\(format(destination.x)), \(format(destination.y))).",
                pointer: pointer()
            )

        case "scroll":
            try requireEventPosting()
            let dx = try boundedScroll(input.delta_x ?? 0, name: "delta_x")
            let dy = try boundedScroll(input.delta_y ?? 0, name: "delta_y")
            guard dx != 0 || dy != 0 else {
                throw DesktopControlError.invalidArgument("delta_x/delta_y", "at least one scroll amount must be non-zero.")
            }
            let unit = try parseScrollUnit(input.scroll_unit)
            try postScroll(deltaX: dx, deltaY: dy, unit: unit)
            return DesktopRunOutput(
                action: action,
                summary: "Scrolled by (\(dx), \(dy)) \(unit.name) unit(s).",
                pointer: pointer()
            )

        case "type_text":
            let text = try requiredNonempty(input.text, name: "text", action: action, allowEmpty: true)
            guard text.count <= maximumTextLength else {
                throw DesktopControlError.invalidArgument("text", "must contain at most \(maximumTextLength) characters.")
            }
            let interval = try boundedDouble(input.interval ?? 0.01, name: "interval", range: 0...1)
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: text.count, interval: interval)
            try requireEventPosting()
            try typeText(text, interval: interval)
            return DesktopRunOutput(
                action: action,
                summary: "Typed \(text.count) character(s) into the focused control.",
                count: text.count
            )

        case "press_key":
            try requireEventPosting()
            let key = try requiredNonempty(input.key, name: "key", action: action)
            let repeatCount = try boundedInteger(input.repeat_count ?? 1, name: "repeat_count", range: 1...100)
            let interval = try boundedDouble(input.interval ?? 0.05, name: "interval", range: 0...1)
            let flags = try modifierFlags(input.modifiers ?? [])
            try pressKey(key, modifiers: flags, repeatCount: repeatCount, interval: interval)
            return DesktopRunOutput(
                action: action,
                summary: "Pressed key '\(key)' \(repeatCount) time(s).",
                count: repeatCount
            )

        case "launch_app":
            let app = try await launchApp(input, context: context)
            return DesktopRunOutput(
                action: action,
                summary: "Launched \(app.localizedName ?? app.bundleIdentifier ?? "application").",
                app: appInfo(app)
            )

        case "activate_app":
            var app = matchingRunningApp(input, defaultToFrontmost: false)
            if app == nil, input.launch_if_needed ?? false {
                app = try await launchApp(input, context: context)
            }
            guard let app else { throw DesktopControlError.appNotFound }
            guard app.activate(options: [.activateAllWindows]) else {
                throw DesktopControlError.operationFailed("macOS refused to activate the selected application.")
            }
            guard let activeProbe = try await waitForApplicationProbe(
                pid: app.processIdentifier,
                timeout: 2,
                where: { $0.exists && $0.is_active }
            ) else {
                throw DesktopControlError.operationFailed("The selected application did not become active before timeout.")
            }
            return DesktopRunOutput(
                action: action,
                summary: "Activated \(app.localizedName ?? app.bundleIdentifier ?? "application").",
                app: appInfo(app, probe: activeProbe)
            )

        case "hide_app":
            let app = try selectedRunningApp(input)
            let initialProbe = try await applicationProbe(pid: app.processIdentifier)
            if !initialProbe.is_hidden {
                _ = app.hide()
            }
            guard let hiddenProbe = try await waitForApplicationProbe(
                pid: app.processIdentifier,
                timeout: 2,
                where: { $0.exists && $0.is_hidden }
            ) else {
                throw DesktopControlError.operationFailed("The selected application did not become hidden before timeout.")
            }
            return DesktopRunOutput(
                action: action,
                summary: "Hid \(app.localizedName ?? "application").",
                app: appInfo(app, probe: hiddenProbe)
            )

        case "unhide_app":
            let app = try selectedRunningApp(input)
            let initialProbe = try await applicationProbe(pid: app.processIdentifier)
            if initialProbe.is_hidden {
                _ = app.unhide()
            }
            guard let visibleProbe = try await waitForApplicationProbe(
                pid: app.processIdentifier,
                timeout: 2,
                where: { $0.exists && !$0.is_hidden }
            ) else {
                throw DesktopControlError.operationFailed("The selected application did not become visible before timeout.")
            }
            return DesktopRunOutput(
                action: action,
                summary: "Unhid \(app.localizedName ?? "application").",
                app: appInfo(app, probe: visibleProbe)
            )

        case "terminate_app":
            let app = try selectedRunningApp(input)
            let before = appInfo(app)
            let forced = input.force ?? false
            let accepted = forced ? app.forceTerminate() : app.terminate()
            guard accepted else {
                throw DesktopControlError.operationFailed("macOS refused to terminate the selected application.")
            }
            return DesktopRunOutput(
                action: action,
                summary: forced ? "Force-terminated \(app.localizedName ?? "application")." : "Requested termination of \(app.localizedName ?? "application").",
                app: before
            )

        case "focus_window":
            let selection = try selectedAXWindow(input)
            if let app = NSRunningApplication(processIdentifier: selection.pid) {
                _ = app.activate(options: [.activateAllWindows])
            }
            let raiseResult = AXUIElementPerformAction(selection.element, kAXRaiseAction as CFString)
            guard raiseResult == .success else {
                throw DesktopControlError.accessibilityFailed("raise window", raiseResult)
            }
            _ = AXUIElementSetAttributeValue(selection.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(selection.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Focused the selected window.", window: window)

        case "move_window":
            let selection = try selectedAXWindow(input)
            let point = try requiredPoint(x: input.x, y: input.y, action: action)
            try setAXPoint(selection.element, attribute: kAXPositionAttribute as CFString, point: point, operation: "move window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Moved the selected window.", window: window)

        case "resize_window":
            let selection = try selectedAXWindow(input)
            let width = try positiveFinite(input.width, name: "width", action: action)
            let height = try positiveFinite(input.height, name: "height", action: action)
            try setAXSize(selection.element, attribute: kAXSizeAttribute as CFString, size: CGSize(width: width, height: height), operation: "resize window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Resized the selected window.", window: window)

        case "minimize_window":
            let selection = try selectedAXWindow(input)
            guard let state = input.state else {
                throw DesktopControlError.missingArgument("state", action)
            }
            try setAXBoolean(selection.element, attribute: kAXMinimizedAttribute as CFString, value: state, operation: "set minimized state")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: state ? "Minimized the selected window." : "Restored the selected window.", window: window)

        case "set_fullscreen":
            let selection = try selectedAXWindow(input)
            guard let state = input.state else {
                throw DesktopControlError.missingArgument("state", action)
            }
            try setAXBoolean(selection.element, attribute: axFullScreenAttribute, value: state, operation: "set fullscreen state")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: state ? "Entered fullscreen for the selected window." : "Exited fullscreen for the selected window.", window: window)

        case "close_window":
            let selection = try selectedAXWindow(input)
            let before = axWindowInfo(selection)
            let closeButton = try copyAXElement(selection.element, attribute: kAXCloseButtonAttribute as CFString, operation: "read close button")
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            guard result == .success else {
                throw DesktopControlError.accessibilityFailed("close window", result)
            }
            return DesktopRunOutput(action: action, summary: "Closed the selected window.", window: before)

        case "read_clipboard":
            let value = NSPasteboard.general.string(forType: .string)
            return DesktopRunOutput(
                action: action,
                summary: value == nil ? "The clipboard does not contain plain text." : "Read \(value?.count ?? 0) character(s) from the clipboard.",
                clipboard_text: value,
                count: value?.count ?? 0
            )

        case "write_clipboard":
            let text = try requiredNonempty(input.text, name: "text", action: action, allowEmpty: true)
            guard text.count <= maximumTextLength else {
                throw DesktopControlError.invalidArgument("text", "must contain at most \(maximumTextLength) characters.")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw DesktopControlError.operationFailed("macOS refused to write plain text to the clipboard.")
            }
            return DesktopRunOutput(action: action, summary: "Wrote \(text.count) character(s) to the clipboard.", count: text.count)

        case "open":
            try await openTarget(input, context: context)
            return DesktopRunOutput(action: action, summary: "Opened the requested URL or file.")

        case "wait":
            let duration = try boundedDouble(
                input.duration ?? { throw DesktopControlError.missingArgument("duration", action) }(),
                name: "duration",
                range: 0...30
            )
            let started = Date()
            try await Task.sleep(for: .seconds(duration))
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            return DesktopRunOutput(action: action, summary: "Waited \(format(duration)) second(s).", elapsed_ms: elapsed)

        default:
            throw DesktopControlError.invalidAction(action)
        }
    }

    // MARK: Permissions and system state

    private static func permissions() -> DesktopPermissions {
        DesktopPermissions(
            accessibility: AXIsProcessTrusted(),
            screen_recording: CGPreflightScreenCaptureAccess(),
            event_posting: CGPreflightPostEventAccess()
        )
    }

    private static func requestPermissions() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
        _ = CGRequestPostEventAccess()
    }

    private static func requireEventPosting() throws {
        guard CGPreflightPostEventAccess() else {
            throw DesktopControlError.permissionRequired(
                "Input control permission is required. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Accessibility."
            )
        }
    }

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw DesktopControlError.permissionRequired(
                "Accessibility permission is required for window control. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Accessibility."
            )
        }
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func displays() -> [DesktopDisplayInfo] {
        let screens = NSScreen.screens.sorted { lhs, rhs in
            let lhsID = displayID(for: lhs)
            let rhsID = displayID(for: rhs)
            if CGDisplayIsMain(lhsID) != 0 { return true }
            if CGDisplayIsMain(rhsID) != 0 { return false }
            return lhs.frame.origin.x < rhs.frame.origin.x
        }
        return screens.enumerated().map { offset, screen in
            let id = displayID(for: screen)
            return DesktopDisplayInfo(
                capture_index: offset + 1,
                display_id: id,
                name: screen.localizedName,
                is_main: CGDisplayIsMain(id) != 0,
                bounds: DesktopRect(CGDisplayBounds(id)),
                pixel_width: CGDisplayPixelsWide(id),
                pixel_height: CGDisplayPixelsHigh(id),
                scale_factor: Double(screen.backingScaleFactor)
            )
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private static func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func pointer() -> DesktopPoint {
        DesktopPoint(currentPointerLocation())
    }

    // MARK: Applications

    private static func runningApps(matching input: DesktopRunInput) -> [NSRunningApplication] {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let filtered = apps.filter { app in
            if let pid = input.pid, app.processIdentifier != pid { return false }
            if let bundleID = input.bundle_id?.nilIfBlank,
               app.bundleIdentifier?.caseInsensitiveCompare(bundleID) != .orderedSame { return false }
            if let name = input.app_name?.nilIfBlank,
               app.localizedName?.localizedCaseInsensitiveContains(name) != true { return false }
            return true
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
            let right = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    private static func matchingRunningApp(_ input: DesktopRunInput, defaultToFrontmost: Bool) -> NSRunningApplication? {
        if let pid = input.pid {
            return NSRunningApplication(processIdentifier: pid)
        }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let bundleID = input.bundle_id?.nilIfBlank {
            return apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }
        }
        if let name = input.app_name?.nilIfBlank {
            return apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
                ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
        }
        return defaultToFrontmost ? NSWorkspace.shared.frontmostApplication : nil
    }

    private static func selectedRunningApp(_ input: DesktopRunInput) throws -> NSRunningApplication {
        guard let app = matchingRunningApp(input, defaultToFrontmost: false) else {
            throw DesktopControlError.appNotFound
        }
        return app
    }

    private static func applicationProbe(pid: pid_t, timeout: TimeInterval = 2) async throws -> DesktopAppProbe {
        guard let executableURL = Bundle.main.executableURL else {
            throw DesktopControlError.operationFailed("Could not locate the desktop feature executable for an application-state probe.")
        }
        let result = try await DesktopProcess.run(
            executableURL: executableURL,
            arguments: [DesktopInternalCommand.appProbeFlag, String(pid)],
            timeout: timeout, maximumOutputBytes: 65_536
        )
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopControlError.operationFailed(
                detail.isEmpty
                    ? "The application-state probe exited with status \(result.exitCode)."
                    : "The application-state probe failed: \(detail)"
            )
        }
        do {
            return try JSONDecoder().decode(DesktopAppProbe.self, from: result.stdoutData)
        } catch {
            throw DesktopControlError.operationFailed(
                "The application-state probe returned invalid data: \(error.localizedDescription)"
            )
        }
    }

    private static func waitForApplicationProbe(
        pid: pid_t,
        timeout: TimeInterval,
        where condition: (DesktopAppProbe) -> Bool
    ) async throws -> DesktopAppProbe? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var attempt = 0
        while let childTimeout = DesktopProbePolicy.childTimeout(remaining: seconds(clock.now.duration(to: deadline))) {
            try Task.checkCancellation()
            let probe = try await applicationProbe(pid: pid, timeout: childTimeout)
            if condition(probe) { return probe }
            let delay = DesktopProbePolicy.retryDelay(attempt: attempt, remaining: seconds(clock.now.duration(to: deadline)))
            if delay <= 0 { break }
            try await Task.sleep(for: .seconds(delay))
            attempt += 1
        }
        return nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func appInfo(
        _ app: NSRunningApplication,
        probe: DesktopAppProbe? = nil
    ) -> DesktopAppInfo {
        let policy: String
        switch app.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        return DesktopAppInfo(
            pid: app.processIdentifier,
            name: app.localizedName,
            bundle_id: app.bundleIdentifier,
            bundle_path: app.bundleURL?.path,
            activation_policy: policy,
            is_active: probe?.is_active ?? app.isActive,
            is_hidden: probe?.is_hidden ?? app.isHidden,
            is_terminated: probe?.is_terminated ?? app.isTerminated
        )
    }

    private static func launchApp(_ input: DesktopRunInput, context: FeatureContext) async throws -> NSRunningApplication {
        let arguments: [String]
        let launchedBundleURL: URL?
        if let appPath = input.app_path?.nilIfBlank {
            let resolved = context.resolvePath(appPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                throw DesktopControlError.invalidArgument("app_path", "must identify an existing .app bundle.")
            }
            arguments = [resolved.path]
            launchedBundleURL = resolved.standardizedFileURL
        } else if let bundleID = input.bundle_id?.nilIfBlank {
            arguments = ["-b", bundleID]
            launchedBundleURL = nil
        } else if let appName = input.app_name?.nilIfBlank {
            arguments = ["-a", appName]
            launchedBundleURL = nil
        } else {
            throw DesktopControlError.missingArgument("app_path, bundle_id, or app_name", "launch_app")
        }

        let timeout = try boundedDouble(input.timeout ?? 5, name: "timeout", range: 0...30)
        let result = try await runProcess(executable: "/usr/bin/open", arguments: arguments)
        guard result.status == 0 else {
            throw DesktopControlError.processFailed("Could not launch the application: \(result.message)")
        }

        var observedApp: NSRunningApplication?
        let ready = try await DesktopProbePolicy.waitForLaunch(timeout: timeout, observe: { childTimeout in
            let matchedApp = matchingRunningApp(input, defaultToFrontmost: false)
                ?? launchedBundleURL.flatMap { expectedURL in
                    NSWorkspace.shared.runningApplications.first {
                        $0.bundleURL?.standardizedFileURL == expectedURL
                    }
                }
            guard let matchedApp else { return false }
            observedApp = matchedApp
            let probe = try await applicationProbe(pid: matchedApp.processIdentifier, timeout: childTimeout)
            return probe.exists && probe.is_finished_launching
        })
        if ready, let observedApp { return observedApp }

        if observedApp != nil {
            throw DesktopControlError.operationFailed(
                "The application process appeared, but it did not finish launching before timeout."
            )
        }
        throw DesktopControlError.operationFailed(
            "The application launch command succeeded, but no matching running application appeared before timeout."
        )
    }

    private static func openTarget(_ input: DesktopRunInput, context: FeatureContext) async throws {
        let target = try requiredNonempty(input.target, name: "target", action: "open")
        let resolvedTarget: String
        if let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty {
            let deniedSchemes = ["javascript", "data"]
            guard !deniedSchemes.contains(scheme.lowercased()) else {
                throw DesktopControlError.invalidArgument("target", "the \(scheme) URL scheme is not allowed.")
            }
            resolvedTarget = target
        } else {
            let fileURL = context.resolvePath(target)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw DesktopControlError.invalidArgument("target", "file does not exist: \(fileURL.path)")
            }
            resolvedTarget = fileURL.path
        }

        var arguments: [String] = []
        if let bundleID = input.bundle_id?.nilIfBlank {
            arguments += ["-b", bundleID]
        } else if let appName = input.app_name?.nilIfBlank {
            arguments += ["-a", appName]
        }
        arguments.append(resolvedTarget)
        let result = try await runProcess(executable: "/usr/bin/open", arguments: arguments)
        guard result.status == 0 else {
            throw DesktopControlError.processFailed("Could not open the target: \(result.message)")
        }
    }

    // MARK: Quartz windows

    private static func windowRecords(onScreenOnly: Bool, matching input: DesktopRunInput) -> [DesktopWindowInfo] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })

        return dictionaries.compactMap { dictionary in
            guard let number = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }

            let app = appsByPID[pid]
            let appName = (dictionary[kCGWindowOwnerName as String] as? String) ?? app?.localizedName
            let bundleID = app?.bundleIdentifier
            let title = (dictionary[kCGWindowName as String] as? String)?.nilIfBlank
            let onScreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

            if let selectorPID = input.pid, selectorPID != pid { return nil }
            if let selectorBundle = input.bundle_id?.nilIfBlank,
               bundleID?.caseInsensitiveCompare(selectorBundle) != .orderedSame { return nil }
            if let selectorApp = input.app_name?.nilIfBlank,
               appName?.localizedCaseInsensitiveContains(selectorApp) != true { return nil }
            if let selectorTitle = input.title?.nilIfBlank,
               title?.localizedCaseInsensitiveContains(selectorTitle) != true { return nil }
            if let selectorID = input.window_id, selectorID != number { return nil }

            return DesktopWindowInfo(
                window_id: number,
                pid: pid,
                app_name: appName,
                bundle_id: bundleID,
                title: title,
                bounds: DesktopRect(bounds),
                layer: layer,
                is_on_screen: onScreen,
                alpha: alpha,
                is_focused: nil,
                is_minimized: onScreenOnly ? false : nil,
                is_fullscreen: nil
            )
        }
    }

    private static func selectedQuartzWindow(_ input: DesktopRunInput) throws -> DesktopWindowInfo {
        try DesktopSafetyPolicy.validateSelectors(windowID: input.window_id, windowIndex: input.window_index)
        let records: [DesktopWindowInfo]
        if input.window_id != nil {
            records = windowRecords(onScreenOnly: false, matching: input)
        } else if input.pid != nil || input.bundle_id?.nilIfBlank != nil || input.app_name?.nilIfBlank != nil || input.title?.nilIfBlank != nil {
            records = windowRecords(onScreenOnly: false, matching: input)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            var copy = input
            copy = DesktopRunInput(copying: copy, pidOverride: frontmost.processIdentifier)
            records = windowRecords(onScreenOnly: false, matching: copy)
        } else {
            records = []
        }
        let index = try boundedInteger(input.window_index ?? 0, name: "window_index", range: 0...500)
        guard records.indices.contains(index) else { throw DesktopControlError.windowNotFound }
        return records[index]
    }

    // MARK: Accessibility windows

    private struct AXWindowSelection {
        let element: AXUIElement
        let pid: pid_t
        let expected: DesktopWindowInfo?
    }

    private struct AXWindowCandidate {
        let element: AXUIElement
        let title: String?
        let frame: CGRect?
        var identity: DesktopSafetyPolicy.WindowIdentity { .init(title: title, frame: frame) }
    }

    private static func selectedAXWindow(_ input: DesktopRunInput) throws -> AXWindowSelection {
        try DesktopSafetyPolicy.validateSelectors(windowID: input.window_id, windowIndex: input.window_index)
        try requireAccessibility()

        let expected = input.window_id.flatMap { id in
            windowRecords(onScreenOnly: false, matching: DesktopRunInput(copying: input, windowIDOverride: id)).first
        }
        let pid = try DesktopWindowSelectionPolicy.selectedProcessID(
            requestedWindowID: input.window_id,
            matchingWindowPID: expected?.pid,
            fallbackProcessID: {
                matchingRunningApp(input, defaultToFrontmost: true)?.processIdentifier
            }
        )

        let application = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
        guard result == .success else {
            throw DesktopControlError.accessibilityFailed("read application windows", result)
        }
        guard let elements = rawWindows as? [AXUIElement] else {
            throw DesktopControlError.windowNotFound
        }

        var candidates = elements.map { element in
            AXWindowCandidate(
                element: element,
                title: copyAXString(element, attribute: kAXTitleAttribute as CFString),
                frame: axFrame(element)
            )
        }

        if let title = input.title?.nilIfBlank {
            candidates = candidates.filter { $0.title?.localizedCaseInsensitiveContains(title) == true }
        }

        if let expected {
            let identity = windowIdentity(expected)
            let index = try DesktopSafetyPolicy.uniqueMatch(candidates.map(\.identity), expected: identity)
            // Check the reverse association too: one AX element can otherwise
            // appear unique when Quartz exposes two indistinguishable windows.
            let quartz = windowRecords(onScreenOnly: false, matching: DesktopRunInput(windowLookupPID: pid, title: nil))
            let quartzIndex = try DesktopSafetyPolicy.uniqueMatch(quartz.map(windowIdentity), expected: candidates[index].identity)
            guard quartz[quartzIndex].window_id == expected.window_id else {
                throw DesktopControlError.windowNotFound
            }
            return AXWindowSelection(element: candidates[index].element, pid: pid, expected: expected)
        }

        let index = try boundedInteger(input.window_index ?? 0, name: "window_index", range: 0...500)
        guard candidates.indices.contains(index) else { throw DesktopControlError.windowNotFound }
        return AXWindowSelection(element: candidates[index].element, pid: pid, expected: expected)
    }

    private static func windowIdentity(_ window: DesktopWindowInfo) -> DesktopSafetyPolicy.WindowIdentity {
        .init(title: window.title, frame: CGRect(x: window.bounds.x, y: window.bounds.y,
                                               width: window.bounds.width, height: window.bounds.height))
    }

    private static func axWindowInfo(_ selection: AXWindowSelection) -> DesktopWindowInfo {
        let frame = axFrame(selection.element) ?? .zero
        let app = NSRunningApplication(processIdentifier: selection.pid)
        let title = copyAXString(selection.element, attribute: kAXTitleAttribute as CFString)
        let records = windowRecords(
            onScreenOnly: false,
            matching: DesktopRunInput(windowLookupPID: selection.pid, title: nil)
        )
        let index = try? DesktopSafetyPolicy.uniqueMatch(
            records.map(windowIdentity), expected: .init(title: title, frame: axFrame(selection.element))
        )
        let matchedWindow = index.map { records[$0] }
        var verifiedWindowID: UInt32?
        if let matchedWindow {
            let application = AXUIElementCreateApplication(selection.pid)
            var rawWindows: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
               let elements = rawWindows as? [AXUIElement] {
                let identities = elements.map {
                    DesktopSafetyPolicy.WindowIdentity(
                        title: copyAXString($0, attribute: kAXTitleAttribute as CFString), frame: axFrame($0)
                    )
                }
                if let axIndex = try? DesktopSafetyPolicy.uniqueMatch(identities, expected: windowIdentity(matchedWindow)),
                   CFEqual(elements[axIndex], selection.element) {
                    verifiedWindowID = matchedWindow.window_id
                }
            }
        }

        return DesktopWindowInfo(
            window_id: verifiedWindowID,
            pid: selection.pid,
            app_name: app?.localizedName ?? matchedWindow?.app_name,
            bundle_id: app?.bundleIdentifier ?? matchedWindow?.bundle_id,
            title: title ?? matchedWindow?.title,
            bounds: DesktopRect(frame),
            layer: matchedWindow?.layer ?? 0,
            is_on_screen: matchedWindow?.is_on_screen ?? !(copyAXBoolean(selection.element, attribute: kAXMinimizedAttribute as CFString) ?? false),
            alpha: matchedWindow?.alpha ?? 1,
            is_focused: copyAXBoolean(selection.element, attribute: kAXFocusedAttribute as CFString),
            is_minimized: copyAXBoolean(selection.element, attribute: kAXMinimizedAttribute as CFString),
            is_fullscreen: copyAXBoolean(selection.element, attribute: axFullScreenAttribute)
        )
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let point = copyAXPoint(element, attribute: kAXPositionAttribute as CFString),
              let size = copyAXSize(element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private static func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func copyAXBoolean(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func copyAXPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func copyAXSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func copyAXElement(_ element: AXUIElement, attribute: CFString, operation: String) throws -> AXUIElement {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard result == .success else {
            throw DesktopControlError.accessibilityFailed(operation, result)
        }
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw DesktopControlError.operationFailed("Accessibility did not return a usable element for '\(operation)'.")
        }
        return raw as! AXUIElement
    }

    private static func setAXPoint(_ element: AXUIElement, attribute: CFString, point: CGPoint, operation: String) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw DesktopControlError.operationFailed("Could not encode the requested window position.")
        }
        let result = AXUIElementSetAttributeValue(element, attribute, value)
        guard result == .success else { throw DesktopControlError.accessibilityFailed(operation, result) }
    }

    private static func setAXSize(_ element: AXUIElement, attribute: CFString, size: CGSize, operation: String) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw DesktopControlError.operationFailed("Could not encode the requested window size.")
        }
        let result = AXUIElementSetAttributeValue(element, attribute, value)
        guard result == .success else { throw DesktopControlError.accessibilityFailed(operation, result) }
    }

    private static func setAXBoolean(_ element: AXUIElement, attribute: CFString, value: Bool, operation: String) throws {
        let result = AXUIElementSetAttributeValue(element, attribute, value ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == .success else { throw DesktopControlError.accessibilityFailed(operation, result) }
    }

    // MARK: Screenshot artifacts

    private static func screenshot(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        let scope = (input.scope?.nilIfBlank ?? "display").lowercased()
        let delay = try boundedDouble(input.delay ?? 0, name: "delay", range: 0...30)
        let label = try sanitizedLabel(input.label)

        var arguments = ["-x", "-tpng"]
        var displayIndex: Int?
        var windowID: UInt32?
        var region: CGRect?

        switch scope {
        case "display":
            let index = input.display_index ?? 1
            guard displays().contains(where: { $0.capture_index == index }) else {
                throw DesktopControlError.invalidArgument("display_index", "no display has capture index \(index); call system_info.")
            }
            arguments.append("-D\(index)")
            displayIndex = index
        case "window":
            let selected = try selectedQuartzWindow(input)
            guard let selectedID = selected.window_id else { throw DesktopControlError.windowNotFound }
            arguments.append("-l\(selectedID)")
            if !(input.include_shadow ?? true) { arguments.append("-o") }
            windowID = selectedID
        case "region":
            let origin = try requiredPoint(x: input.x, y: input.y, action: action)
            let width = try positiveFinite(input.width, name: "width", action: action)
            let height = try positiveFinite(input.height, name: "height", action: action)
            let selectedRegion = try DesktopSafetyPolicy.captureRegion(
                x: Double(origin.x), y: Double(origin.y), width: width, height: height
            )
            guard DesktopSafetyPolicy.intersects(selectedRegion.rect, displays: displayBounds()) else {
                throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region does not intersect an attached display.")
            }
            arguments.append(selectedRegion.argument)
            region = selectedRegion.rect
        default:
            throw DesktopControlError.invalidArgument("scope", "must be display, window, or region.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopControlError.permissionRequired(
                "Screen Recording permission is required. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        let root = try artifactDirectory(context: context)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = root.appendingPathComponent("\(label)-\(timestamp)-\(UUID().uuidString).png")
        if input.include_cursor ?? false { arguments.append("-C") }
        arguments.append(url.path)

        do {
            let result = try await runProcess(executable: "/usr/sbin/screencapture", arguments: arguments)
            guard result.status == 0 else {
                throw DesktopControlError.processFailed("Screenshot capture failed: \(result.message)")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DesktopControlError.operationFailed("screencapture reported success but did not create a PNG artifact.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw DesktopControlError.operationFailed("The screenshot artifact is empty.")
            }
            let dimensions = pngDimensions(data)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let artifact = DesktopScreenshotArtifact(
                path: url.path,
                mime_type: "image/png",
                size_bytes: data.count,
                sha256: digest,
                pixel_width: dimensions?.width,
                pixel_height: dimensions?.height,
                scope: scope,
                display_index: displayIndex,
                window_id: windowID,
                region: region.map(DesktopRect.init),
                created_at: ISO8601DateFormatter().string(from: Date())
            )
            try pruneArtifacts(in: root, keeping: maximumArtifacts)
            return DesktopRunOutput(
                action: action,
                summary: "Captured a \(scope) screenshot to \(url.path).",
                artifact: artifact,
                note: "The PNG is attached to the model's multimodal tool context and retained as a private desktop feature artifact."
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func artifactDirectory(context: FeatureContext) throws -> URL {
        let root: URL
        if let configured = context.environment["ZENCODE_SUPPORT_DIRECTORY"]?.nilIfBlank {
            root = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        } else if let home = context.environment["HOME"]?.nilIfBlank {
            root = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".zencode", isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zencode", isDirectory: true)
        }
        let directory = root
            .appendingPathComponent("desktop", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.standardizedFileURL
    }

    private static func sanitizedLabel(_ value: String?) throws -> String {
        guard let value = value?.nilIfBlank else { return "screenshot" }
        guard value.count <= 64 else {
            throw DesktopControlError.invalidArgument("label", "must contain at most 64 characters.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
        let sanitized = value.components(separatedBy: allowed).filter { !$0.isEmpty }.joined(separator: "-")
        guard !sanitized.isEmpty else {
            throw DesktopControlError.invalidArgument("label", "must contain a letter, number, hyphen, or underscore.")
        }
        return sanitized
    }

    private static func pruneArtifacts(in directory: URL, keeping maximum: Int) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { url in
                guard url.pathExtension.lowercased() == "png" else { return false }
                return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in files.dropFirst(maximum) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = Array(data.prefix(24))
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count == 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == [73, 72, 68, 82] else { return nil }
        func value(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = value(16..<20)
        let height = value(20..<24)
        return width > 0 && height > 0 ? (width, height) : nil
    }

    // MARK: Pointer and keyboard

    private struct MouseButtonDefinition {
        let name: String
        let button: CGMouseButton
        let down: CGEventType
        let dragged: CGEventType
        let up: CGEventType
    }

    private struct ScrollUnitDefinition {
        let name: String
        let unit: CGScrollEventUnit
    }

    private static func parseMouseButton(_ value: String?) throws -> MouseButtonDefinition {
        switch (value?.nilIfBlank ?? "left").lowercased() {
        case "left": return MouseButtonDefinition(name: "left", button: .left, down: .leftMouseDown, dragged: .leftMouseDragged, up: .leftMouseUp)
        case "right": return MouseButtonDefinition(name: "right", button: .right, down: .rightMouseDown, dragged: .rightMouseDragged, up: .rightMouseUp)
        case "middle": return MouseButtonDefinition(name: "middle", button: .center, down: .otherMouseDown, dragged: .otherMouseDragged, up: .otherMouseUp)
        default: throw DesktopControlError.invalidArgument("button", "must be left, right, or middle.")
        }
    }

    private static func parseScrollUnit(_ value: String?) throws -> ScrollUnitDefinition {
        switch (value?.nilIfBlank ?? "pixel").lowercased() {
        case "pixel": return ScrollUnitDefinition(name: "pixel", unit: .pixel)
        case "line": return ScrollUnitDefinition(name: "line", unit: .line)
        default: throw DesktopControlError.invalidArgument("scroll_unit", "must be pixel or line.")
        }
    }

    private static func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw DesktopControlError.operationFailed("Could not create a Quartz HID event source.")
        }
        return source
    }

    private static func movePointer(to destination: CGPoint, duration: Double) throws {
        let source = try eventSource()
        let start = currentPointerLocation()
        let steps = duration == 0 ? 1 : min(max(Int((duration * 60).rounded()), 1), 240)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (destination.x - start.x) * progress,
                y: start.y + (destination.y - start.y) * progress
            )
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                throw DesktopControlError.operationFailed("Could not create a mouse movement event.")
            }
            event.post(tap: .cghidEventTap)
            if duration > 0 { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }
    }

    private static func click(button: MouseButtonDefinition, count: Int) throws {
        let source = try eventSource()
        let location = currentPointerLocation()
        for clickIndex in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: button.down, mouseCursorPosition: location, mouseButton: button.button),
                  let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: location, mouseButton: button.button) else {
                throw DesktopControlError.operationFailed("Could not create mouse click events.")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            if clickIndex < count { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    private static func dragPointer(from start: CGPoint, to destination: CGPoint, duration: Double, button: MouseButtonDefinition) throws {
        try movePointer(to: start, duration: 0)
        let source = try eventSource()
        guard let down = CGEvent(mouseEventSource: source, mouseType: button.down, mouseCursorPosition: start, mouseButton: button.button) else {
            throw DesktopControlError.operationFailed("Could not create the drag mouse-down event.")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)

        let steps = duration == 0 ? 1 : min(max(Int((duration * 60).rounded()), 1), 240)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (destination.x - start.x) * progress,
                y: start.y + (destination.y - start.y) * progress
            )
            guard let event = CGEvent(mouseEventSource: source, mouseType: button.dragged, mouseCursorPosition: point, mouseButton: button.button) else {
                if let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: point, mouseButton: button.button) {
                    up.post(tap: .cghidEventTap)
                }
                throw DesktopControlError.operationFailed("Could not create a drag movement event.")
            }
            event.post(tap: .cghidEventTap)
            if duration > 0 { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: button.up, mouseCursorPosition: destination, mouseButton: button.button) else {
            throw DesktopControlError.operationFailed("Could not create the drag mouse-up event.")
        }
        up.post(tap: .cghidEventTap)
    }

    private static func postScroll(deltaX: Int32, deltaY: Int32, unit: ScrollUnitDefinition) throws {
        let source = try eventSource()
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: unit.unit,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw DesktopControlError.operationFailed("Could not create a scroll event.")
        }
        event.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String, interval: Double) throws {
        try Task.checkCancellation()
        let source = try eventSource()
        for character in text {
            try Task.checkCancellation()
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw DesktopControlError.operationFailed("Could not create Unicode keyboard events.")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
    }

    private static func pressKey(_ name: String, modifiers: CGEventFlags, repeatCount: Int, interval: Double) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keyCode = keyCodes[normalized] else {
            throw DesktopControlError.invalidArgument(
                "key",
                "unsupported key '\(name)'. Use type_text for arbitrary text; common letters, digits, punctuation, arrows, navigation keys, return/tab/escape/delete, and F1-F20 are supported."
            )
        }
        let source = try eventSource()
        for index in 0..<repeatCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw DesktopControlError.operationFailed("Could not create keyboard events.")
            }
            down.flags = modifiers
            up.flags = modifiers
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            if index + 1 < repeatCount, interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
    }

    private static func modifierFlags(_ values: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for value in values {
            switch value.lowercased() {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw DesktopControlError.invalidArgument("modifiers", "unsupported modifier '\(value)'.")
            }
        }
        return flags
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f17": 64, "keypad_decimal": 65, "keypad_multiply": 67, "keypad_plus": 69, "keypad_clear": 71,
        "volume_up": 72, "volume_down": 73, "mute": 74, "keypad_divide": 75, "keypad_enter": 76,
        "keypad_minus": 78, "f18": 79, "f19": 80, "keypad_equals": 81, "keypad_0": 82,
        "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87,
        "keypad_6": 88, "keypad_7": 89, "f20": 90, "keypad_8": 91, "keypad_9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "help": 114, "home": 115, "page_up": 116, "forward_delete": 117, "f4": 118, "end": 119,
        "f2": 120, "page_down": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    // MARK: Validation and process helpers

    private struct ProcessResult {
        let status: Int32
        let stderr: String

        var message: String {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "process exited with status \(status)." : trimmed
        }
    }

    private static func runProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        let result = try await DesktopProcess.run(
            executableURL: URL(fileURLWithPath: executable), arguments: arguments
        )
        return ProcessResult(status: result.exitCode, stderr: String(decoding: result.stderrData, as: UTF8.self))
    }

    private static func requiredNonempty(_ value: String?, name: String, action: String, allowEmpty: Bool = false) throws -> String {
        guard let value else { throw DesktopControlError.missingArgument(name, action) }
        if !allowEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DesktopControlError.invalidArgument(name, "must not be empty.")
        }
        return value
    }

    private static func requiredPoint(
        x: Double?,
        y: Double?,
        action: String,
        xName: String = "x",
        yName: String = "y"
    ) throws -> CGPoint {
        guard let x else { throw DesktopControlError.missingArgument(xName, action) }
        guard let y else { throw DesktopControlError.missingArgument(yName, action) }
        guard x.isFinite else { throw DesktopControlError.invalidArgument(xName, "must be finite.") }
        guard y.isFinite else { throw DesktopControlError.invalidArgument(yName, "must be finite.") }
        return CGPoint(x: x, y: y)
    }

    private static func positiveFinite(_ value: Double?, name: String, action: String) throws -> Double {
        guard let value else { throw DesktopControlError.missingArgument(name, action) }
        guard value.isFinite, value > 0 else {
            throw DesktopControlError.invalidArgument(name, "must be a finite number greater than zero.")
        }
        return value
    }

    private static func boundedDouble(_ value: Double, name: String, range: ClosedRange<Double>) throws -> Double {
        guard value.isFinite, range.contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private static func boundedInteger(_ value: Int, name: String, range: ClosedRange<Int>) throws -> Int {
        guard range.contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private static func boundedScroll(_ value: Double, name: String) throws -> Int32 {
        guard value.isFinite, (-10_000...10_000).contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between -10000 and 10000.")
        }
        return Int32(value.rounded())
    }

    private static func movementDuration(_ value: Double?) throws -> Double {
        try boundedDouble(value ?? 0.2, name: "duration", range: 0...10)
    }

    private static func displayBounds() -> [CGRect] {
        NSScreen.screens.map { CGDisplayBounds(displayID(for: $0)) }
    }

    private static func validateDesktopPoint(_ point: CGPoint, argument: String) throws {
        guard DesktopSafetyPolicy.contains(point, displays: displayBounds()) else {
            throw DesktopControlError.invalidArgument(argument, "point lies outside all attached displays; call system_info for global bounds.")
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }
}

private extension DesktopRunInput {
    init(copying source: DesktopRunInput, pidOverride: Int32? = nil, windowIDOverride: UInt32? = nil) {
        self.init(
            action: source.action,
            x: source.x, y: source.y, to_x: source.to_x, to_y: source.to_y,
            width: source.width, height: source.height, duration: source.duration, interval: source.interval,
            button: source.button, click_count: source.click_count, delta_x: source.delta_x, delta_y: source.delta_y,
            scroll_unit: source.scroll_unit, text: source.text, key: source.key, modifiers: source.modifiers,
            repeat_count: source.repeat_count, scope: source.scope, display_index: source.display_index,
            window_id: windowIDOverride ?? source.window_id, include_cursor: source.include_cursor, include_shadow: source.include_shadow,
            delay: source.delay, label: source.label, pid: pidOverride ?? source.pid, bundle_id: source.bundle_id,
            app_name: source.app_name, app_path: source.app_path, title: source.title,
            window_index: source.window_index, on_screen_only: source.on_screen_only, limit: source.limit,
            launch_if_needed: source.launch_if_needed, force: source.force, state: source.state,
            timeout: source.timeout, target: source.target
        )
    }

    init(windowLookupPID pid: Int32, title: String?) {
        self.init(
            action: "list_windows",
            x: nil, y: nil, to_x: nil, to_y: nil, width: nil, height: nil, duration: nil, interval: nil,
            button: nil, click_count: nil, delta_x: nil, delta_y: nil, scroll_unit: nil,
            text: nil, key: nil, modifiers: nil, repeat_count: nil, scope: nil, display_index: nil,
            window_id: nil, include_cursor: nil, include_shadow: nil, delay: nil, label: nil,
            pid: pid, bundle_id: nil, app_name: nil, app_path: nil, title: title, window_index: nil,
            on_screen_only: nil, limit: nil, launch_if_needed: nil, force: nil, state: nil, timeout: nil, target: nil
        )
    }

}

private enum DesktopInternalCommand {
    static let appProbeFlag = "--desktop-internal-app-probe"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count == 3, arguments[1] == appProbeFlag else {
            return false
        }

        let app = Int32(arguments[2]).flatMap { pid in
            pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        }
        let probe = DesktopAppProbe(
            exists: app != nil && app?.isTerminated == false,
            is_active: app?.isActive ?? false,
            is_hidden: app?.isHidden ?? false,
            is_terminated: app?.isTerminated ?? true,
            is_finished_launching: app?.isFinishedLaunching ?? false
        )
        if let data = try? JSONEncoder().encode(probe) {
            FileHandle.standardOutput.write(data)
        }
        return true
    }
}

@main
private enum DesktopFeatureMain {
    static func main() async {
        if DesktopInternalCommand.runIfRequested() {
            return
        }
        await FeatureRunner.run([
            AnyFeatureTool(DesktopRunTool())
        ])
    }
}
