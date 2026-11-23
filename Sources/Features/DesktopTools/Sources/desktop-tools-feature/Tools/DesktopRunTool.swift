//  Created by Gerardo Grisolini on 30/05/26.
//
import FeatureKit
import Foundation
import ToolCore

struct DesktopRunTool: FeatureTool {
    static let name = "desktop.run"
    static let description = "Controls the local macOS desktop through explicit typed actions. It can inspect permissions/system state, list apps and windows, list a window's Accessibility elements and press, focus, or set them, read the texts of a window (read_text), capture PNG screenshots of a window, display, region, or element, zoom into a region or an element at native resolution, move/click/drag/scroll the pointer, type text or key shortcuts, launch/activate/hide/terminate apps, manipulate windows through Accessibility, use the text clipboard, open a URL/file, and wait (for a time, or with wait_for until an app, window, or element is in the expected state). Call action=permissions first. The lists (list_apps, list_windows, list_elements, read_text) are paged: a response holds at most limit entries and about 8000 characters of them, and when more remain it carries next_offset, which you pass as offset in the next call with the same arguments. list_apps shows regular apps (those with a Dock icon) unless include_background=true, and query filters it by name or bundle_id; list_elements returns compact elements (ref, role, label, value, and the actions that press or adjust them) unless include_details=true, which adds frame, center, and every attribute. read_text returns the texts of a window as texts[] entries with role and text, static text included, which list_elements leaves out by default because it lists only interactive elements (the result shown by Calculator is static text): text is the element's value, else its label, at most 500 characters, and include_details=true adds ref and frame. Prefer list_elements with press_element, focus_element, set_value, or click/type_text with element_ref, query, or identifier (the exact AXIdentifier) over raw coordinates: element actions work from text alone, so they also work for models that cannot see images. An element_ref whose element moved in its window (for example a row inserted above it) is relocated when exactly one element of that window still has its role and fingerprint; the result then carries a note and the new ref. action=batch runs up to 20 steps, each with the fields of a desktop.run call, in order in one call (for example several press_element calls and a final list_elements) and reports every step; it refuses, before running anything, the steps that may need operator approval, could hide a dangerous key sequence, or attach images (open, launch_app, terminate_app, activate_app with launch_if_needed, type_text with line breaks, press_key, screenshot, zoom, request_permissions), which must be separate calls. activate_app waits up to timeout (default 5 s) until the app is the frontmost one and its windows are in front, and returns its main or focused window in window; when the sources that report the frontmost app still disagree at the end, it succeeds with a note, so check with list_windows or a screenshot before acting. action=wait_for replaces guessing a wait duration: it polls every 0.25 s until condition holds (app_active: the app selected by pid, bundle_id, or app_name is frontmost; window_present or window_absent: a window selected by those or by window_id or title exists or is gone; element_present or element_absent: an element selected by element_ref, query, identifier, and/or role exists or is gone in the selected window), and returns what it found with elapsed_ms, or fails after timeout (0-30, default 5) saying what it last saw; an absence is never confirmed by a search that stopped early or skipped nodes that did not respond. click and scroll report the element under the pointer and drag the element under its destination (role, label, app, window), and type_text and press_key report the app and element with keyboard focus, so check them before continuing. Keyboard and element input that would go into the application hosting this zen session (for example the terminal running zen), including a click by element_ref or query and close_window on its windows, is refused unless that app is selected explicitly with its pid, its bundle_id, or its exact app_name. Screen capture requires Screen Recording; input, window, and element actions require Accessibility/Event Posting. Coordinates use the global Quartz desktop space in points, with the origin at the upper-left of the main display; system_info reports each display's bounds and list_windows each window's bounds. Screenshots use point scale: one image pixel is one desktop point, and artifact.desktop_bounds with artifact.points_per_pixel maps image pixel (px, py) to the desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). Use zoom to read small details at native resolution. screenshot and zoom also accept element_ref, or query, identifier, and role (selected like press_element, in the window selected like list_elements), instead of a region: they capture the frame of that element, limited to its display (artifact.scope is element, and element describes it), which is far smaller and more legible than the whole display. When scope is omitted, screenshot chooses it: element with element_ref, query, or identifier; region with x, y, width, or height; display with display_index; window with window_id, title, window_index, pid, bundle_id, or app_name; otherwise the topmost visible window of at least 100x100 points that does not belong to the app hosting this zen session, or the display when there is none. A note says which scope was chosen, and scope=display captures the whole screen. The screenshot PNG is attached to the model's multimodal tool context; models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows, list_elements, and read_text. Opening anything other than a plain http/https URL, launching an app from a path, and terminating an app may require operator approval. The tool itself never runs caller-supplied shell or AppleScript code."

    static let inputSchema = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "permissions", "request_permissions", "system_info", "list_apps", "list_windows",
            "list_elements", "read_text", "press_element", "focus_element", "set_value",
            "screenshot", "zoom", "move_mouse", "click", "drag", "scroll", "type_text", "press_key",
            "launch_app", "activate_app", "hide_app", "unhide_app", "terminate_app",
            "focus_window", "move_window", "resize_window", "minimize_window",
            "set_fullscreen", "close_window", "read_clipboard", "write_clipboard", "open", "wait", "wait_for", "batch"
          ],
          "description": "Operation to perform. list_windows lists windows front to back, each with is_on_screen, is_frontmost_app, and hosts_zen (the app running this zen session, which is not the app to control) when true, and from Accessibility its subrole (AXStandardWindow, AXDialog, AXFloatingWindow, AXSystemDialog...), is_main, is_focused, and is_minimized when known; windows with is_on_screen false are minimized, hidden, or on another Space, so check subrole and title before taking one for a dialog. list_elements lists a window's Accessibility elements (interactive ones by default) in compact form: element_ref as ref, role, label (the distinct title, description, and placeholder texts joined with ' | '), value (omitted when equal to the label), actions (only AXPress, AXConfirm, AXPick, AXIncrement, AXDecrement, AXShowMenu, and AXCancel, omitted when none), enabled only when false, and focused only when true; include_details=true returns every attribute instead (subrole, title, description, placeholder, identifier, value_settable, frame, center, all actions, pid, app_name, window_title) plus label. read_text lists the texts of a window, for models that cannot see images: it visits every element, not only the interactive ones, so it also returns static text such as the result of a Calculator, which list_elements hides unless interactive_only=false (read_text ignores interactive_only), in the same window as list_elements (window_id, title, window_index, or an app selector; by default the focused window of the frontmost app) and filtered by query, role, and identifier. Each texts[] entry has role and text; with include_details=true also ref and frame. text is the element's value as text, never that of a secure text field, when it is not blank, otherwise its label (the distinct title, description, and placeholder texts joined with ' | '); it is trimmed, at most 500 characters (a longer one is cut and ends in '...', with a note), and blank texts and a text equal to the previous one are left out. list_apps lists regular apps by default (include_background=true adds accessory and prohibited ones such as menu-bar agents and helpers) and accepts query. list_apps, list_windows, list_elements, and read_text are paged with limit and offset, and when more entries remain, or the response reaches its size budget, next_offset gives the offset to continue from. press_element (AXPress), focus_element, and set_value act on one element chosen by element_ref, or by query and/or identifier, and click and type_text accept them instead of coordinates; prefer these over coordinates, since they work without seeing screenshots. batch runs steps in order (see steps) and returns steps[] with each step's index, action, ok, summary or error, note, and payloads; a failed step does not fail the call. click and scroll report the element under the pointer, and drag the element under its destination; type_text and press_key report the focused element and its app, and stop when the keyboard focus moves to another app. activate_app waits up to timeout (default 5 s) until the app is the frontmost one and, when it has windows on screen, until its first window in front-to-back order is its own, then returns its main or focused window in window; when the sources that report the frontmost app still disagree at the end (for example the app-state probe says the app is active but Accessibility reports another one), it does not fail: note explains the discrepancy and frontmost_app names the app Accessibility reports, so verify with list_windows or a screenshot before acting; it fails only when the app does not become active at all. wait_for waits until the condition of condition holds, polling every 0.25 s, so use it instead of a fixed wait after activate_app, after opening a dialog, or after pressing a button: it returns app (app_active), window (window_present), or element in compact form unless include_details (element_present), always with elapsed_ms, and fails after timeout (0-30, default 5) with an error that says what it last saw (for example no window matching title 'Save' of TextEdit, and which app is frontmost). element_absent is never satisfied by a search that stopped early (budget, nodes that did not respond), and window_absent with title is not satisfied without Screen Recording, which hides the titles of other apps' windows; they keep polling and the error says why. screenshot captures a window, display, region, or element, chosen by scope, and zoom a region or element: with element_ref, or query, identifier, and role, they capture that element's frame (limited to its display), found like press_element in the window selected like list_elements, and report it in element and artifact.scope element; they do not combine with x, y, width, height, or display_index. When scope is omitted, screenshot chooses it, and a note says which: element with an element selector, region with x, y, width, or height, display with display_index, window with window_id, title, window_index, pid, bundle_id, or app_name, otherwise the topmost visible window of at least 100x100 points that does not belong to the app hosting this zen session (the display when there is none), so the image is a legible window rather than a whole screen; pass scope=display for the whole screen. screenshot and zoom report the frontmost app in frontmost_app. type_text, press_key, press_element, focus_element, set_value, click by element_ref or query, and close_window refuse to act on the app hosting this zen session unless its pid, its bundle_id, or its exact app_name selects it. request_permissions may display macOS consent prompts. open (except plain http/https URLs), launching an app from a path, and terminate_app may require operator approval and fail when it is denied."
        },
        "x": { "type": "number", "description": "Global desktop X coordinate in points: pointer target for move_mouse, click, and scroll; optional start X for drag; region origin for screenshot scope=region and zoom; window origin for move_window. Omit for click, screenshot, and zoom with element_ref, query, or identifier." },
        "y": { "type": "number", "description": "Global desktop Y coordinate in points: pointer target for move_mouse, click, and scroll; optional start Y for drag; region origin for screenshot scope=region and zoom; window origin for move_window. Omit for click, screenshot, and zoom with element_ref, query, or identifier." },
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
        "scope": { "type": "string", "enum": ["display", "window", "region", "element"], "description": "Screenshot scope: display (display_index, default the main one), window (selected by window_id, title, window_index, or pid, bundle_id, app_name; by default the frontmost app's), region (x, y, width, height), or element (element_ref, or query, identifier, and role). When omitted it is chosen from the other arguments: element with element_ref, query, or identifier; region with x, y, width, or height; display with display_index; window with window_id, title, window_index, pid, bundle_id, or app_name; otherwise the topmost visible window of at least 100x100 points (layer 0, on screen, not transparent) that does not belong to the app hosting this zen session, or the display when there is none. The response note says which scope was chosen; pass scope=display for the whole screen. An explicit scope is kept as given. zoom ignores it, except that with an element selector it must be element or omitted." },
        "display_index": { "type": "integer", "minimum": 1, "description": "1-based display index from system_info; 1 is the main display." },
        "window_id": { "type": "integer", "minimum": 1, "description": "Quartz window ID from list_windows; preferred for exact window selection, also for wait_for window_present and window_absent." },
        "include_cursor": { "type": "boolean", "description": "Include the pointer in display, region, and zoom captures; defaults to false." },
        "include_shadow": { "type": "boolean", "description": "Include the window shadow in window screenshots; defaults to false. With the shadow, image pixels no longer map exactly to desktop coordinates." },
        "delay": { "type": "number", "minimum": 0, "maximum": 30, "description": "Delay in seconds before a screenshot or zoom capture." },
        "label": { "type": "string", "maxLength": 64, "description": "Optional safe filename label for the generated screenshot or zoom artifact." },
        "pid": { "type": "integer", "minimum": 1, "description": "Application process ID selector. For type_text and press_key the selected app is activated before any input; it also selects the window for list_elements and query, selects the app of wait_for (app_active, window and element conditions), and explicitly authorizes input into the app hosting zen." },
        "bundle_id": { "type": "string", "description": "Application bundle identifier selector; same input semantics as pid." },
        "app_name": { "type": "string", "description": "Application display name selector; exact matches are preferred. terminate_app, and input into the app hosting this zen session, require the exact, case-insensitive name. Same input semantics as pid." },
        "app_path": { "type": "string", "description": "Absolute or working-directory-relative .app path for launch_app." },
        "title": { "type": "string", "description": "Case-insensitive window-title substring selector, also for wait_for window conditions (the titles of other apps' windows need Screen Recording)." },
        "window_index": { "type": "integer", "minimum": 0, "maximum": 500, "description": "0-based index after filtering windows; defaults to 0." },
        "on_screen_only": { "type": "boolean", "description": "For list_windows, omit off-screen/minimized windows; defaults to false." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum number of entries returned by list_apps, list_windows, list_elements, and read_text; defaults to 100. The entries of a response are also cut at about 8000 characters, so fewer may be returned (always at least one): when entries remain, next_offset gives the offset to continue from." },
        "offset": { "type": "integer", "minimum": 0, "maximum": 5000, "description": "Number of entries to skip in list_apps, list_windows, list_elements, and read_text, to read the next page of a list: pass the next_offset of the previous response, with the same other arguments. Defaults to 0." },
        "include_background": { "type": "boolean", "description": "For list_apps, also list accessory and prohibited apps (menu-bar agents, daemons, helpers); by default only regular apps, those with a Dock icon, are listed. Defaults to false." },
        "include_details": { "type": "boolean", "description": "For read_text: add ref and frame to each text. For list_elements, and for the element that wait_for element_present returns: return every attribute of each element (subrole, role_description, title, description, placeholder, identifier, value_settable, frame, center, all actions, pid, app_name, window_title) plus label, instead of the compact form (ref, role, label, value, the press and adjust actions, enabled only when false, focused only when true). Defaults to false." },
        "launch_if_needed": { "type": "boolean", "description": "For activate_app, launch a missing app first; defaults to false." },
        "force": { "type": "boolean", "description": "For terminate_app, force termination instead of requesting a clean quit." },
        "state": { "type": "boolean", "description": "Required target state for minimize_window and set_fullscreen." },
        "timeout": { "type": "number", "minimum": 0, "maximum": 30, "description": "Seconds to wait, 0-30, defaulting to 5 in every action that uses it: for an app to finish launching (launch_app, and activate_app with launch_if_needed), for an activated app to become the frontmost one with its windows in front (activate_app), for an app to quit (terminate_app), and for the condition of wait_for to hold. With 0 these actions observe once and do not wait." },
        "condition": { "type": "string", "enum": ["app_active", "window_present", "window_absent", "element_present", "element_absent"], "description": "Required for wait_for: what to wait for. app_active: the app selected by pid, bundle_id, or app_name is the frontmost app. window_present, window_absent: a window selected by app (pid, bundle_id, app_name) and/or window_id and title exists, or no longer exists, on screen or not; at least one app or window selector is required, and the absence of a window by title is not confirmed without Screen Recording. element_present, element_absent: an element selected by element_ref, query, identifier, and/or role exists in the selected window (app and window selectors as for list_elements; by default the focused window of the frontmost app), or no longer does; interactive_only and max_depth apply (interactive_only defaults to true: pass false to wait for static text, sheets, or other non-interactive elements), and an absence is not confirmed by a search that stopped early or skipped nodes that did not respond. Polling every 0.25 s until timeout." },
        "target": { "type": "string", "description": "URL or file path for open; file: URLs are treated as file paths." },
        "element_ref": { "type": "string", "maxLength": 1024, "description": "Opaque element reference returned by list_elements (or in the element or focused_element of click, scroll, drag, type_text, and press_key) for press_element, focus_element, set_value, click, type_text, screenshot and zoom (which capture the element's frame), and wait_for element_present and element_absent. Pass it unchanged. When its path no longer leads to its element (siblings were inserted or removed, for example a row added above it), it is relocated if a complete search of the same window finds exactly one element with the same role and fingerprint (role, subrole, title, description, identifier): the action proceeds, its note says element_ref was relocated, and its element carries the new ref to use from now on. It is never relocated into another window or app. Otherwise, once the element disappears or its role, subrole, title, description, or identifier change, it fails with a stale-reference error, so call list_elements again. Do not combine with query, identifier, or x/y (for screenshot and zoom, x/y/width/height and display_index), nor with title or window_index (the reference already identifies its window; window_id is accepted only when it is that window). scroll, drag, move_mouse, and press_key do not accept it, and read_text does not use it." },
        "query": { "type": "string", "maxLength": 200, "description": "Case- and diacritic-insensitive text matched against element title, description, value, placeholder, identifier, and role description. For list_apps, a case- and diacritic-insensitive substring of the app name or bundle_id that keeps only the matching apps. Filters list_elements and read_text, and is one of the selectors of wait_for element_present and element_absent; for press_element, focus_element, set_value, click, type_text, screenshot, and zoom it selects the single matching element in the selected window (default: the focused window of the frontmost app), alone or together with identifier, preferring a unique exact title/description/placeholder match and failing with candidates when ambiguous; when the search stops early (node or time budget, too many matches) or skips nodes that do not respond, so the visit is incomplete, only a single exact match is acted on. scroll, drag, move_mouse, and press_key do not accept it." },
        "role": { "type": "string", "maxLength": 64, "description": "Accessibility role or subrole filter for list_elements, read_text, query, identifier, and wait_for (where it can be the only element selector), such as AXButton, button, TextField, or AXSearchField; case-insensitive, AX prefix optional." },
        "interactive_only": { "type": "boolean", "description": "For list_elements, query, identifier, and wait_for element conditions, keep only interactive elements: buttons, fields, menus, links, sliders, tabs, elements exposing AXPress/AXConfirm/AXPick, or with a settable value. Defaults to true; read_text ignores it and reads every element, and for screenshot and zoom by query or identifier it decides which elements can be selected (pass false to select static text)." },
        "max_depth": { "type": "integer", "minimum": 1, "maximum": 60, "description": "Maximum Accessibility tree depth below the window visited by list_elements, read_text, query, identifier, and wait_for element conditions; defaults to 30." },
        "identifier": { "type": "string", "maxLength": 256, "description": "Exact, case-sensitive AXIdentifier of an element (list_elements reports it with include_details=true). Filters list_elements and read_text, and is one of the selectors of wait_for element_present and element_absent; for press_element, focus_element, set_value, click, type_text, screenshot, and zoom it selects the element, alone or with query and role: a single match wins, also when the search stops early, and several matches fail with candidates. Do not combine with element_ref or x/y; scroll, drag, move_mouse, and press_key do not accept it." },
        "steps": {
          "type": "array",
          "minItems": 1,
          "maxItems": 20,
          "description": "For batch: 1-20 steps run in order, each an object with the same fields as a desktop.run call. Every step's action and batch safety policy are validated before the first runs, and a refused step fails the whole call naming its index; each step's own arguments are validated when that step runs, so an argument error can leave earlier steps applied: steps cannot be batch, screenshot, zoom, request_permissions, open, launch_app, terminate_app, or press_key, nor activate_app with launch_if_needed=true or type_text whose text has a line break or another control character than tab (these may need operator approval, could hide a dangerous key sequence, or attach images); call them on their own. A step inherits pid, bundle_id, and app_name from the batch when it has none of the three, and window_id and title when it has none of window_id, title, window_index, and element_ref; nothing else is inherited. Each step gets the same checks as its own call, including the protection of the app hosting zen. The batch has a 60-second time budget: before each step, a step whose estimated duration (typing, wait, wait_for, activate_app, pointer movement) does not fit in the time left is skipped with the rest, and a step estimated over 60 s is refused. A wait_for step is estimated at its timeout (default 5 s).",
          "items": {
            "type": "object",
            "required": ["action"],
            "description": "One step: a desktop.run call object. This nested schema constrains action; the other fields are decoded with the top-level types and validated for the action when the step runs, where action is required and must be one allowed in a batch.",
            "properties": {
              "action": {
                "type": "string",
                "enum": [
                  "permissions", "system_info", "list_apps", "list_windows", "list_elements", "read_text",
                  "press_element", "focus_element", "set_value", "move_mouse", "click", "drag", "scroll",
                  "type_text", "activate_app", "hide_app", "unhide_app",
                  "focus_window", "move_window", "resize_window", "minimize_window", "set_fullscreen",
                  "close_window", "read_clipboard", "write_clipboard", "wait", "wait_for"
                ],
                "description": "Operation of the step, as for a desktop.run call."
              }
            }
          }
        },
        "stop_on_error": { "type": "boolean", "description": "For batch: stop at the first step that fails and report the remaining steps as skipped; defaults to true. With false every step runs and the summary counts the failures. A failed step never makes the batch call fail." }
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
        "count": { "type": "integer", "minimum": 0, "description": "Number of entries returned: apps, windows, elements, or texts of a list, otherwise the action-specific count." },
        "next_offset": { "type": "integer", "minimum": 0, "description": "list_apps, list_windows, list_elements, and read_text: the offset that continues the list (the offset of this page plus count). Present only when more entries remain; pass it as offset with the same other arguments." },
        "elapsed_ms": { "type": "integer", "minimum": 0, "description": "wait and wait_for: the milliseconds waited." },
        "note": { "type": "string" },
        "elements": { "type": "array", "items": { "$ref": "#/$defs/element" }, "description": "list_elements entries: compact (ref, role, label, value, actions, enabled only when false, focused only when true) unless include_details was true." },
        "texts": { "type": "array", "items": { "$ref": "#/$defs/text_item" }, "description": "read_text entries: role and text (the element's value, else its label, trimmed and at most 500 characters), plus ref and frame with include_details; blank texts and consecutive repeats are left out." },
        "element": { "$ref": "#/$defs/element", "description": "The element acted on or captured: in compact form for screenshot and zoom of an element." },
        "focused_element": { "$ref": "#/$defs/element" },
        "focus_method": { "type": "string", "enum": ["accessibility", "click"] },
        "frontmost_app": { "$ref": "#/$defs/app" },
        "steps": { "type": "array", "items": { "$ref": "#/$defs/batch_step" }, "description": "batch: the outcome of every step, in order. To stay within the response size budget, the payloads of the steps may be reduced, with a note (lists first, then compact elements, then the fields of the earlier steps)." }
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
            "scope": { "type": "string", "description": "display, window, region, or element; zoom of a region reports zoom, and screenshot or zoom of an element reports element." }, "display_index": { "type": "integer" },
            "window_id": { "type": "integer" }, "region": { "$ref": "#/$defs/rect" },
            "desktop_bounds": { "$ref": "#/$defs/rect" },
            "points_per_pixel": { "type": "number", "exclusiveMinimum": 0 },
            "created_at": { "type": "string" }
          }
        },
        "text_item": {
          "type": "object",
          "required": ["role", "text"],
          "properties": {
            "role": { "type": "string" },
            "text": { "type": "string", "maxLength": 500, "description": "The element's value as text (never for secure text fields), else its label: the distinct non-empty title, description, and placeholder texts joined with ' | '. Trimmed; a longer text is cut to 500 characters and ends in '...'." },
            "ref": { "type": "string", "maxLength": 1024, "description": "element_ref of the element; only with include_details; omitted when its window cannot be anchored." },
            "frame": { "$ref": "#/$defs/rect", "description": "Only with include_details." }
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
            "hosts_zen": { "type": "boolean", "const": true },
            "label": { "type": "string", "description": "list_elements, and the compact element and focused_element of a reduced batch step: the distinct non-empty title, description, and placeholder texts, in that order, joined with ' | '." }
          }
        },
        "batch_step": {
          "type": "object",
          "required": ["index", "action", "ok"],
          "properties": {
            "index": { "type": "integer", "minimum": 1, "description": "1-based position of the step in steps." },
            "action": { "type": "string" },
            "ok": { "type": "boolean", "description": "True when the step ran and succeeded." },
            "summary": { "type": "string", "description": "Present when the step succeeded." },
            "error": { "type": "string", "description": "Present when the step failed: its error message." },
            "note": { "type": "string" },
            "skipped": { "type": "boolean", "const": true, "description": "Present when the step did not run: an earlier step failed with stop_on_error, or the time budget had no room for it." },
            "permissions": { "$ref": "#/properties/permissions" },
            "system": { "$ref": "#/properties/system" },
            "element": { "$ref": "#/$defs/element" },
            "focused_element": { "$ref": "#/$defs/element" },
            "app": { "$ref": "#/$defs/app" },
            "window": { "$ref": "#/$defs/window" },
            "elements": { "type": "array", "items": { "$ref": "#/$defs/element" } },
            "texts": { "type": "array", "items": { "$ref": "#/$defs/text_item" } },
            "windows": { "type": "array", "items": { "$ref": "#/$defs/window" } },
            "apps": { "type": "array", "items": { "$ref": "#/$defs/app" } },
            "clipboard_text": { "type": "string" },
            "count": { "type": "integer", "minimum": 0 },
            "next_offset": { "type": "integer", "minimum": 0 }
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
