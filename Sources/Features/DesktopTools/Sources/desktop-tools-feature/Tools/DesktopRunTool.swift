//  Created by Gerardo Grisolini on 30/05/26.
//
import FeatureKit
import Foundation
import ToolCore

struct DesktopRunTool: FeatureTool {
    static let name = "desktop.run"
    static let description = "Controls the local macOS desktop through explicit typed actions. It can inspect permissions/system state, list apps and windows, list a window's Accessibility elements and press, focus, or set them, capture PNG screenshots of a display/window/region, zoom into a region at native resolution, move/click/drag/scroll the pointer, type text or key shortcuts, launch/activate/hide/terminate apps, manipulate windows through Accessibility, use the text clipboard, open a URL/file, and wait. Call action=permissions first. Prefer list_elements with press_element, focus_element, set_value, or click/type_text with element_ref or query over raw coordinates: element actions work from text alone, so they also work for models that cannot see images. click and scroll report the element under the pointer and drag the element under its destination (role, label, app, window), and type_text and press_key report the app and element with keyboard focus, so check them before continuing. Keyboard and element input that would go into the application hosting this zen session (for example the terminal running zen), including a click by element_ref or query and close_window on its windows, is refused unless that app is selected explicitly with its pid, its bundle_id, or its exact app_name. Screen capture requires Screen Recording; input, window, and element actions require Accessibility/Event Posting. Coordinates use the global Quartz desktop space in points, with the origin at the upper-left of the main display; system_info reports each display's bounds and list_windows each window's bounds. Screenshots use point scale: one image pixel is one desktop point, and artifact.desktop_bounds with artifact.points_per_pixel maps image pixel (px, py) to the desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). Use zoom to read small details at native resolution. The screenshot PNG is attached to the model's multimodal tool context; models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows and list_elements. Opening anything other than a plain http/https URL, launching an app from a path, and terminating an app may require operator approval. The tool itself never runs caller-supplied shell or AppleScript code."

    static let inputSchema = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "permissions", "request_permissions", "system_info", "list_apps", "list_windows",
            "list_elements", "press_element", "focus_element", "set_value",
            "screenshot", "zoom", "move_mouse", "click", "drag", "scroll", "type_text", "press_key",
            "launch_app", "activate_app", "hide_app", "unhide_app", "terminate_app",
            "focus_window", "move_window", "resize_window", "minimize_window",
            "set_fullscreen", "close_window", "read_clipboard", "write_clipboard", "open", "wait"
          ],
          "description": "Operation to perform. list_windows lists windows front to back, each with is_on_screen, is_frontmost_app, and hosts_zen (the app running this zen session, which is not the app to control) when true, and from Accessibility its subrole (AXStandardWindow, AXDialog, AXFloatingWindow, AXSystemDialog...), is_main, is_focused, and is_minimized when known; windows with is_on_screen false are minimized, hidden, or on another Space, so check subrole and title before taking one for a dialog. list_elements lists a window's Accessibility elements (interactive ones by default), each with role, label texts, frame, center, and an element_ref. press_element (AXPress), focus_element, and set_value act on one element chosen by element_ref or query, and click and type_text accept element_ref or query instead of coordinates; prefer these over coordinates, since they work without seeing screenshots. click and scroll report the element under the pointer, and drag the element under its destination; type_text and press_key report the focused element and its app, and stop when the keyboard focus moves to another app. screenshot and zoom report the frontmost app in frontmost_app. type_text, press_key, press_element, focus_element, set_value, click by element_ref or query, and close_window refuse to act on the app hosting this zen session unless its pid, its bundle_id, or its exact app_name selects it. request_permissions may display macOS consent prompts. open (except plain http/https URLs), launching an app from a path, and terminate_app may require operator approval and fail when it is denied."
        },
        "x": { "type": "number", "description": "Global desktop X coordinate in points: pointer target for move_mouse, click, and scroll; optional start X for drag; region origin for screenshot scope=region and zoom; window origin for move_window. Omit for click with element_ref or query." },
        "y": { "type": "number", "description": "Global desktop Y coordinate in points: pointer target for move_mouse, click, and scroll; optional start Y for drag; region origin for screenshot scope=region and zoom; window origin for move_window. Omit for click with element_ref or query." },
        "to_x": { "type": "number", "description": "Required destination X for drag." },
        "to_y": { "type": "number", "description": "Required destination Y for drag." },
        "width": { "type": "number", "exclusiveMinimum": 0, "description": "Width in points of the screenshot region, the zoom region, or the window for resize_window." },
        "height": { "type": "number", "exclusiveMinimum": 0, "description": "Height in points of the screenshot region, the zoom region, or the window for resize_window." },
        "duration": { "type": "number", "minimum": 0, "maximum": 30, "description": "Seconds: pointer movement for move_mouse, click, scroll, and drag (0-10, default 0.2), or the wait duration (0-30)." },
        "interval": { "type": "number", "minimum": 0, "maximum": 1, "description": "Delay between typed characters or repeated keys." },
        "button": { "type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button; defaults to left." },
        "click_count": { "type": "integer", "minimum": 1, "maximum": 3, "description": "Single, double, or triple click count." },
        "delta_x": { "type": "number", "minimum": -10000, "maximum": 10000, "description": "Horizontal scroll amount; positive scrolls left." },
        "delta_y": { "type": "number", "minimum": -10000, "maximum": 10000, "description": "Vertical scroll amount; positive scrolls up." },
        "scroll_unit": { "type": "string", "enum": ["pixel", "line"], "description": "Scroll unit; defaults to pixel." },
        "text": { "type": "string", "maxLength": 10000, "description": "Text for type_text, set_value, or write_clipboard. type_text presses the real keys of the current keyboard layout; line breaks press Return (submitting the line, so text with line breaks requires the same consent as local.exec) and tabs press Tab. type_text inserts at the insertion point and does not clear the field (after a focus click the caret may be anywhere in it); to replace the content, use set_value, or press_key key=a with modifiers=[command] before typing. set_value replaces the element's AXValue and never presses Return." },
        "key": { "type": "string", "description": "Key for press_key: a single character, resolved on the current keyboard layout (Shift/Option are added automatically when the layout needs them), or a named key such as return, tab, space, escape, delete, forward_delete, left, right, up, down, home, end, page_up, page_down, f1-f20, keypad_0-keypad_9." },
        "modifiers": { "type": "array", "uniqueItems": true, "items": { "type": "string", "enum": ["command", "shift", "option", "control", "fn"] }, "description": "Modifiers held for press_key." },
        "repeat_count": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Number of key presses; defaults to 1." },
        "scope": { "type": "string", "enum": ["display", "window", "region"], "description": "Screenshot scope; defaults to display." },
        "display_index": { "type": "integer", "minimum": 1, "description": "1-based display index from system_info; 1 is the main display." },
        "window_id": { "type": "integer", "minimum": 1, "description": "Quartz window ID from list_windows; preferred for exact window selection." },
        "include_cursor": { "type": "boolean", "description": "Include the pointer in display, region, and zoom captures; defaults to false." },
        "include_shadow": { "type": "boolean", "description": "Include the window shadow in window screenshots; defaults to false. With the shadow, image pixels no longer map exactly to desktop coordinates." },
        "delay": { "type": "number", "minimum": 0, "maximum": 30, "description": "Delay in seconds before a screenshot or zoom capture." },
        "label": { "type": "string", "maxLength": 64, "description": "Optional safe filename label for the generated screenshot or zoom artifact." },
        "pid": { "type": "integer", "minimum": 1, "description": "Application process ID selector. For type_text and press_key the selected app is activated before any input; it also selects the window for list_elements and query, and explicitly authorizes input into the app hosting zen." },
        "bundle_id": { "type": "string", "description": "Application bundle identifier selector; same input semantics as pid." },
        "app_name": { "type": "string", "description": "Application display name selector; exact matches are preferred. terminate_app, and input into the app hosting this zen session, require the exact, case-insensitive name. Same input semantics as pid." },
        "app_path": { "type": "string", "description": "Absolute or working-directory-relative .app path for launch_app." },
        "title": { "type": "string", "description": "Case-insensitive window-title substring selector." },
        "window_index": { "type": "integer", "minimum": 0, "maximum": 500, "description": "0-based index after filtering windows; defaults to 0." },
        "on_screen_only": { "type": "boolean", "description": "For list_windows, omit off-screen/minimized windows; defaults to false." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum list result count for list_apps, list_windows, and list_elements; defaults to 100." },
        "launch_if_needed": { "type": "boolean", "description": "For activate_app, launch a missing app first; defaults to false." },
        "force": { "type": "boolean", "description": "For terminate_app, force termination instead of requesting a clean quit." },
        "state": { "type": "boolean", "description": "Required target state for minimize_window and set_fullscreen." },
        "timeout": { "type": "number", "minimum": 0, "maximum": 30, "description": "Seconds to wait for an app to finish launching (launch_app, activate_app) or to quit (terminate_app); defaults to 5." },
        "target": { "type": "string", "description": "URL or file path for open; file: URLs are treated as file paths." },
        "element_ref": { "type": "string", "maxLength": 1024, "description": "Opaque element reference returned by list_elements (or in the element or focused_element of click, scroll, drag, type_text, and press_key) for press_element, focus_element, set_value, click, and type_text. Pass it unchanged; it fails with a stale-reference error once the element disappears or moves, or its role, subrole, title, description, or identifier change, so call list_elements again. Do not combine with query or x/y, nor with title or window_index (the reference already identifies its window; window_id is accepted only when it is that window). scroll, drag, move_mouse, and press_key do not accept it." },
        "query": { "type": "string", "maxLength": 200, "description": "Case- and diacritic-insensitive text matched against element title, description, value, placeholder, identifier, and role description. Filters list_elements; for press_element, focus_element, set_value, click, and type_text it selects the single matching element in the selected window (default: the focused window of the frontmost app), preferring a unique exact title/description/placeholder match and failing with candidates when ambiguous; when the search stops early (node or time budget, too many matches) or skips nodes that do not respond, so the visit is incomplete, only a single exact match is acted on. scroll, drag, move_mouse, and press_key do not accept it." },
        "role": { "type": "string", "maxLength": 64, "description": "Accessibility role or subrole filter for list_elements and query, such as AXButton, button, TextField, or AXSearchField; case-insensitive, AX prefix optional." },
        "interactive_only": { "type": "boolean", "description": "For list_elements and query, keep only interactive elements: buttons, fields, menus, links, sliders, tabs, elements exposing AXPress/AXConfirm/AXPick, or with a settable value. Defaults to true." },
        "max_depth": { "type": "integer", "minimum": 1, "maximum": 60, "description": "Maximum Accessibility tree depth below the window visited by list_elements and query; defaults to 30." }
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
        "note": { "type": "string" },
        "elements": { "type": "array", "items": { "$ref": "#/$defs/element" } },
        "element": { "$ref": "#/$defs/element" },
        "focused_element": { "$ref": "#/$defs/element" },
        "focus_method": { "type": "string", "enum": ["accessibility", "click"] },
        "frontmost_app": { "$ref": "#/$defs/app" }
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
            "is_hidden": { "type": "boolean" }, "is_terminated": { "type": "boolean" },
            "hosts_zen": { "type": "boolean", "const": true, "description": "Present only for the app hosting this zen session." }
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
            "is_minimized": { "type": "boolean" }, "is_fullscreen": { "type": "boolean" },
            "subrole": { "type": "string", "description": "AXSubrole of the window (AXStandardWindow, AXDialog, AXFloatingWindow, AXSystemDialog...); omitted when Accessibility is unavailable or the window could not be paired." },
            "is_main": { "type": "boolean", "description": "AXMain: the app's main window; omitted when unknown." },
            "is_frontmost_app": { "type": "boolean", "const": true, "description": "Present only when the window's app is the frontmost app." },
            "hosts_zen": { "type": "boolean", "const": true, "description": "Present only for windows of the app hosting this zen session; they are not the app to control." }
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
            "desktop_bounds": { "$ref": "#/$defs/rect" },
            "points_per_pixel": { "type": "number", "exclusiveMinimum": 0 },
            "created_at": { "type": "string" }
          }
        },
        "element": {
          "type": "object",
          "required": ["role"],
          "properties": {
            "ref": { "type": "string", "maxLength": 1024, "description": "Opaque element_ref; omitted when the element's window cannot be anchored." },
            "role": { "type": "string" }, "subrole": { "type": "string" },
            "role_description": { "type": "string" }, "title": { "type": "string" },
            "description": { "type": "string" },
            "value": { "type": "string", "description": "Value as text, truncated to 200 characters; never reported for secure text fields." },
            "placeholder": { "type": "string" }, "identifier": { "type": "string" },
            "enabled": { "type": "boolean" }, "focused": { "type": "boolean" },
            "value_settable": { "type": "boolean" },
            "frame": { "$ref": "#/$defs/rect" }, "center": { "$ref": "#/$defs/point" },
            "actions": { "type": "array", "items": { "type": "string" } },
            "pid": { "type": "integer", "description": "Process ID of the application that owns the element's window, which may differ from the process serving the element (web content, open/save panels)." }, "app_name": { "type": "string" },
            "window_title": { "type": "string" },
            "hosts_zen": { "type": "boolean", "const": true }
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
