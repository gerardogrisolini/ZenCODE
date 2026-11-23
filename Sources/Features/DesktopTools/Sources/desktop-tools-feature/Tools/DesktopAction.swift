//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

/// Every action accepted by `desktop.run`. Raw values match the input schema.
enum DesktopAction: String, CaseIterable, Sendable {
    case permissions
    case requestPermissions = "request_permissions"
    case systemInfo = "system_info"
    case listApps = "list_apps"
    case listWindows = "list_windows"
    case listElements = "list_elements"
    case readText = "read_text"
    case pressElement = "press_element"
    case focusElement = "focus_element"
    case setValue = "set_value"
    case screenshot
    case zoom
    case moveMouse = "move_mouse"
    case click
    case drag
    case scroll
    case typeText = "type_text"
    case pressKey = "press_key"
    case launchApp = "launch_app"
    case activateApp = "activate_app"
    case hideApp = "hide_app"
    case unhideApp = "unhide_app"
    case terminateApp = "terminate_app"
    case focusWindow = "focus_window"
    case moveWindow = "move_window"
    case resizeWindow = "resize_window"
    case minimizeWindow = "minimize_window"
    case setFullscreen = "set_fullscreen"
    case closeWindow = "close_window"
    case readClipboard = "read_clipboard"
    case writeClipboard = "write_clipboard"
    case open
    case wait
    case waitFor = "wait_for"
    case batch

    /// The action name as `execute` and the runtime's consent gate read it:
    /// trimmed and lowercased.
    static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
