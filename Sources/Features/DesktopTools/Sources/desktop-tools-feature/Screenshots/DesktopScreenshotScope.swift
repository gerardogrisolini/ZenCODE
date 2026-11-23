import CoreGraphics
import Foundation
import ToolCore

/// Pure rules for the scope of `screenshot` and `zoom`: which combinations of
/// arguments are refused, which scope a screenshot gets when `scope` is
/// omitted, and the note that says so. The live reads (the windows in Z order,
/// the app hosting zen) are gathered by `DesktopController.screenshot` and
/// passed in.
enum DesktopScreenshotScope {
    /// The values of `scope`.
    static let names = ["display", "window", "region", "element"]
    static let namesPhrase = "display, window, region, or element"
    /// The smallest window, in points on each side, that a screenshot with no
    /// arguments defaults to: smaller ones are tooltips, badges, and slivers.
    static let minimumDefaultWindowSide: CGFloat = 100

    /// The arguments of a screenshot or zoom that decide its scope.
    struct Arguments: Equatable {
        /// `scope` as given, trimmed and lowercased; nil when omitted or blank.
        var scope: String?
        /// element_ref, query, or identifier.
        var hasElementSelectors = false
        /// Any of x, y, width, and height.
        var hasRegion = false
        var hasDisplayIndex = false
        /// window_id, title, or window_index.
        var hasWindowSelectors = false
        /// pid, bundle_id, or app_name.
        var hasAppSelectors = false

        init(
            scope: String? = nil, hasElementSelectors: Bool = false, hasRegion: Bool = false,
            hasDisplayIndex: Bool = false, hasWindowSelectors: Bool = false, hasAppSelectors: Bool = false
        ) {
            self.scope = scope
            self.hasElementSelectors = hasElementSelectors
            self.hasRegion = hasRegion
            self.hasDisplayIndex = hasDisplayIndex
            self.hasWindowSelectors = hasWindowSelectors
            self.hasAppSelectors = hasAppSelectors
        }

        init(_ input: DesktopRunInput) {
            self.init(
                scope: input.scope?.nilIfBlank?.lowercased(),
                hasElementSelectors: input.element_ref?.nilIfBlank != nil
                    || input.query?.nilIfBlank != nil || input.identifier?.nilIfBlank != nil,
                hasRegion: input.x != nil || input.y != nil || input.width != nil || input.height != nil,
                hasDisplayIndex: input.display_index != nil,
                hasWindowSelectors: input.window_id != nil || input.window_index != nil || input.title?.nilIfBlank != nil,
                hasAppSelectors: input.pid != nil || input.bundle_id?.nilIfBlank != nil || input.app_name?.nilIfBlank != nil
            )
        }
    }

    /// The scope a screenshot was given, trimmed and lowercased; nil when
    /// omitted or blank. Refuses anything but `names`.
    static func explicitScope(_ raw: String?) throws -> String? {
        guard let scope = raw?.nilIfBlank?.lowercased() else { return nil }
        guard names.contains(scope) else {
            throw DesktopControlError.invalidArgument("scope", "must be \(namesPhrase).")
        }
        return scope
    }

    // MARK: Validation

    /// Refuses the combinations that cannot be captured: an element (element_ref,
    /// query, or identifier) together with a region or a display_index, or with
    /// a scope other than element; and scope=element without an element. The
    /// window and app selectors may accompany an element: they select the
    /// window that is searched, as for press_element.
    static func validate(_ arguments: Arguments, action: String) throws {
        guard arguments.hasElementSelectors else {
            if arguments.scope == "element" {
                throw DesktopControlError.missingArgument("element_ref, query, or identifier", action)
            }
            return
        }
        if arguments.hasRegion {
            throw DesktopControlError.invalidArgument(
                "x/y/width/height", "must be omitted when element_ref, query, or identifier selects the element to capture."
            )
        }
        if arguments.hasDisplayIndex {
            throw DesktopControlError.invalidArgument(
                "display_index", "must be omitted when element_ref, query, or identifier selects the element to capture."
            )
        }
        if let scope = arguments.scope, scope != "element" {
            throw DesktopControlError.invalidArgument(
                "scope", "must be element, or omitted, when element_ref, query, or identifier selects the element to capture; '\(scope)' captures no element."
            )
        }
    }

    // MARK: Default scope

    /// The scope of a call and, when it was not given, why it was chosen.
    struct Decision {
        /// display, window, region, or element.
        let scope: String
        /// Set only when the scope defaulted: says which scope and how to get the
        /// whole screen.
        let note: String?
        /// The window to capture when the scope defaulted to the frontmost
        /// window; nil when the window is selected by the call's own selectors.
        let window: DesktopWindowInfo?
        /// True when the scope defaulted to window because the call has a window
        /// or app selector.
        let selectedByArguments: Bool

        init(scope: String, note: String? = nil, window: DesktopWindowInfo? = nil, selectedByArguments: Bool = false) {
            self.scope = scope
            self.note = note
            self.window = window
            self.selectedByArguments = selectedByArguments
        }
    }

    static let wholeScreenHint = "pass scope=display for the whole screen"

    /// The scope of a screenshot. An explicit scope is kept as it is, with no
    /// note. When `scope` is omitted, the first of these applies:
    /// 1. an element selector: element;
    /// 2. x, y, width, or height: region;
    /// 3. display_index: display;
    /// 4. a window selector (window_id, title, window_index) or an app selector
    ///    (pid, bundle_id, app_name): window, which `selectedQuartzWindow` resolves;
    /// 5. otherwise the window `frontmostWindow(in:hostPID:)` finds, as window;
    ///    when there is none, display.
    ///
    /// - Parameters:
    ///   - windows: read only for the last rule: the layer 0 windows on screen
    ///     with some alpha, front to back, as CGWindowList orders them.
    ///   - hostPID: the app hosting this zen session, whose windows never count.
    ///   - hostName: its name, for the note.
    static func decide(
        _ arguments: Arguments,
        windows: () -> [DesktopWindowInfo],
        hostPID: Int32?,
        hostName: String? = nil
    ) -> Decision {
        if let scope = arguments.scope { return Decision(scope: scope) }
        if arguments.hasElementSelectors {
            return Decision(scope: "element", note: "scope defaulted to element: the element selected by element_ref, query, or identifier.")
        }
        if arguments.hasRegion {
            return Decision(
                scope: "region",
                note: "scope defaulted to region because x, y, width, or height was given; \(wholeScreenHint)."
            )
        }
        if arguments.hasDisplayIndex {
            return Decision(scope: "display", note: "scope defaulted to display because display_index was given.")
        }
        if arguments.hasWindowSelectors || arguments.hasAppSelectors {
            return Decision(
                scope: "window",
                note: "scope defaulted to window because a window or app selector was given; \(wholeScreenHint).",
                selectedByArguments: true
            )
        }
        if let window = frontmostWindow(in: windows(), hostPID: hostPID) {
            let owner = window.app_name?.nilIfBlank ?? "pid \(window.pid)"
            return Decision(
                scope: "window",
                note: "scope defaulted to the frontmost window of \(owner); \(wholeScreenHint).",
                window: window
            )
        }
        let side = Int(minimumDefaultWindowSide)
        let outside = hostName.map { " outside \($0), the app hosting this zen session," } ?? ""
        return Decision(
            scope: "display",
            note: "scope defaulted to display because no visible window of at least \(side)x\(side) points\(outside) was found."
        )
    }

    /// The window a screenshot with no arguments captures: the first of
    /// `windows` (front to back) that has a window ID, is on layer 0, is on
    /// screen, has some alpha, is at least `minimumDefaultWindowSide` points
    /// on each side, and does not belong to the app hosting zen.
    static func frontmostWindow(in windows: [DesktopWindowInfo], hostPID: Int32?) -> DesktopWindowInfo? {
        windows.first { window in
            window.window_id != nil
                && window.layer == 0
                && window.is_on_screen
                && window.alpha > 0
                && window.bounds.width >= Double(minimumDefaultWindowSide)
                && window.bounds.height >= Double(minimumDefaultWindowSide)
                && (hostPID == nil || window.pid != hostPID)
        }
    }

    /// The error of a window that no longer exists or does not match, when the
    /// scope defaulted to window because of the call's own selectors: the call
    /// used to capture the display then, so say how to get it.
    static func defaultedWindowNotFoundMessage(_ message: String) -> String {
        "\(message) The scope defaulted to window because a window or app selector was given; \(wholeScreenHint)."
    }
}
