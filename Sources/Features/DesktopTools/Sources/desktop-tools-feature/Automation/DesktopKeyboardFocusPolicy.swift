import Foundation

/// Pure rules for re-checking, while keyboard input is sent, that the keyboard
/// focus is still in the app the input is meant for. The live check reads the
/// focused application from Accessibility; without Accessibility there is no
/// re-check, and an Accessibility error counts as the focus being lost.
enum DesktopKeyboardFocusPolicy {
    /// type_text re-reads the focused application every this many characters.
    static let typingCheckInterval = 20

    /// Whether the character presses Return or Tab (a line break or a tab).
    static func isReturnOrTab(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n" || character == "\t"
    }

    /// Whether the focus is re-checked before sending `character` at `index`
    /// (0-based): right before the first one, every `typingCheckInterval`, and
    /// before every line break or tab, so a Return never reaches another app.
    static func checksFocus(beforeCharacter index: Int, character: Character) -> Bool {
        guard index >= 0 else { return false }
        return index % typingCheckInterval == 0 || isReturnOrTab(character)
    }

    enum Input: Equatable {
        case typing(total: Int)
        case keyPresses(total: Int)
    }

    /// "AXTextField 'Search' of Safari", "Safari", or a generic phrase when the
    /// focused application could not be identified.
    static func focusPhrase(appName: String?, element: String?) -> String {
        guard let appName else { return "an application that could not be identified" }
        return element.map { "\($0) of \(appName)" } ?? appName
    }

    /// The error when the focus left `expectedApp` after `sent` characters or
    /// key presses; nothing more is sent.
    static func focusLostMessage(input: Input, sent: Int, expectedApp: String, focus: String) -> String {
        let recover = "Bring \(expectedApp) back with activate_app, focus_window, or focus_element, then retry."
        switch input {
        case let .typing(total):
            guard sent > 0 else {
                return "Keyboard focus is no longer in \(expectedApp): it is in \(focus), so nothing was typed. \(recover)"
            }
            return "Keyboard focus moved from \(expectedApp) to \(focus) after \(sent) of \(total) character(s) were typed; typing stopped. Check \(expectedApp) for the partial text, then type the rest. \(recover)"
        case let .keyPresses(total):
            guard sent > 0 else {
                return "Keyboard focus is no longer in \(expectedApp): it is in \(focus), so no key was pressed. \(recover)"
            }
            return "Keyboard focus moved from \(expectedApp) to \(focus) after \(sent) of \(total) key press(es); the remaining presses were not sent. \(recover)"
        }
    }
}
