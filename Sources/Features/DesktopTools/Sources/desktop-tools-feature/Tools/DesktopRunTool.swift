//  Created by Gerardo Grisolini on 30/05/26.
//
import FeatureKit
import Foundation
import ToolCore

struct DesktopRunTool: FeatureTool {
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
