import CoreFoundation
import CoreGraphics
import Foundation
import ToolCore

/// Pure rules for describing, filtering, and choosing Accessibility elements.
/// The live AX layer only gathers raw attributes and defers every decision here.
enum DesktopElementPolicy {
    static let maximumValueCharacters = 200
    static let maximumQueryCharacters = 200
    static let maximumIdentifierCharacters = 256
    static let maximumRoleFilterCharacters = 64
    static let maximumAmbiguityCandidates = 5
    /// Bounds of one Accessibility tree visit (list_elements and query).
    static let visitNodeBudget = 4_000
    static let visitTimeBudget: Double = 8
    static let secureTextFieldRole = "AXSecureTextField"

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXLink", "AXSlider", "AXIncrementor", "AXDisclosureTriangle"
    ]
    /// Tabs of an AXTabGroup are AXRadioButton/AXTabButton; search and secure
    /// fields are AXTextField subroles.
    static let interactiveSubroles: Set<String> = ["AXSearchField", "AXSecureTextField", "AXTabButton"]
    static let interactiveActions: Set<String> = ["AXPress", "AXConfirm", "AXPick"]
    /// Actions press_element may perform, in preference order.
    static let pressActions = ["AXPress", "AXConfirm", "AXPick"]

    // MARK: Description

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureTextFieldRole || subrole == secureTextFieldRole
    }

    /// Renders an AX attribute value as text: strings as-is, booleans as
    /// true/false, numbers with their decimal form, URLs absolute.
    static func textValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String { return string }
        if let attributed = raw as? NSAttributedString { return attributed.string }
        if let url = raw as? URL { return url.absoluteString }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    static func boundedValue(_ text: String, limit: Int = maximumValueCharacters) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// `valueLimit` bounds `value` (200 characters unless a caller reads more, as
    /// read_text does).
    static func makeInfo(
        role: String,
        subrole: String? = nil,
        roleDescription: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        identifier: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        valueSettable: Bool? = nil,
        frame: CGRect? = nil,
        actions: [String]? = nil,
        pid: Int32? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        hostsZen: Bool = false,
        ref: String? = nil,
        label: String? = nil,
        valueLimit: Int = maximumValueCharacters
    ) -> DesktopElementInfo {
        func clean(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let usableFrame = frame.flatMap { isPositive($0) ? $0 : nil }
        let secure = isSecure(role: role, subrole: subrole)
        return DesktopElementInfo(
            ref: ref,
            role: role,
            subrole: clean(subrole),
            role_description: clean(roleDescription),
            title: clean(title),
            description: clean(description),
            value: secure ? nil : clean(value).map { boundedValue($0, limit: valueLimit) },
            placeholder: clean(placeholder),
            identifier: clean(identifier),
            enabled: enabled,
            focused: focused,
            value_settable: valueSettable,
            frame: usableFrame.map(DesktopRect.init),
            center: usableFrame.map { DesktopPoint(CGPoint(x: $0.midX, y: $0.midY)) },
            actions: actions.flatMap { $0.isEmpty ? nil : $0 },
            pid: pid,
            app_name: clean(appName),
            window_title: clean(windowTitle),
            hosts_zen: hostsZen ? true : nil,
            label: label
        )
    }

    static func isPositive(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    /// The most human-readable text of an element, for summaries and errors.
    static func label(of element: DesktopElementInfo) -> String? {
        let label = element.title ?? element.description ?? element.placeholder ?? element.value ?? element.identifier
        guard let label else { return nil }
        let singleLine = label.split(whereSeparator: \.isNewline).joined(separator: " ")
        return singleLine.count > 60 ? String(singleLine.prefix(57)) + "..." : singleLine
    }

    /// "AXButton 'Save'", or the bare role when the element has no label.
    static func describe(_ element: DesktopElementInfo) -> String {
        label(of: element).map { "\(element.role) '\($0)'" } ?? element.role
    }

    /// "AXButton 'Save' in Final Cut Pro — window 'Project'".
    static func locationPhrase(_ element: DesktopElementInfo) -> String {
        var phrase = describe(element)
        if let app = element.app_name { phrase += " in \(app)" }
        if let window = element.window_title { phrase += " — window '\(window)'" }
        return phrase
    }

    // MARK: List projection

    /// The only actions the compact projection keeps: those that press, pick,
    /// confirm, step, open the menu of, or cancel an element. The others
    /// (AXScrollToVisible, AXRaise, AXShowDefaultUI...) are noise for a model.
    static let compactActions: [String] = [
        "AXPress", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXShowMenu", "AXCancel"
    ]
    static let labelSeparator = " | "

    /// The distinct, non-blank texts among title, description, and placeholder
    /// (in that order, trimmed) joined with " | "; nil when there is none.
    static func listLabel(title: String?, description: String?, placeholder: String?) -> String? {
        var parts: [String] = []
        for text in [title, description, placeholder] {
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
                  !parts.contains(trimmed) else { continue }
            parts.append(trimmed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: labelSeparator)
    }

    static func listLabel(of element: DesktopElementInfo) -> String? {
        listLabel(title: element.title, description: element.description, placeholder: element.placeholder)
    }

    /// The element as list_elements reports it by default: `ref`, `role`,
    /// `label`, `value` (omitted when equal to the label), the actions of
    /// `compactActions` (omitted when none), `enabled` only when false, and
    /// `focused` only when true. Everything else is dropped. Pure and reusable
    /// by any list of elements.
    static func compact(_ element: DesktopElementInfo) -> DesktopElementInfo {
        let label = listLabel(of: element)
        var compact = DesktopElementInfo(role: element.role)
        compact.ref = element.ref
        compact.label = label
        compact.value = element.value.flatMap { $0 == label ? nil : $0 }
        let actions = (element.actions ?? []).filter(compactActions.contains)
        compact.actions = actions.isEmpty ? nil : actions
        compact.enabled = element.enabled == false ? false : nil
        compact.focused = element.focused == true ? true : nil
        return boundedForOutput(compact)
    }

    /// The element as list_elements reports it with `include_details`: every
    /// attribute, plus `label`.
    static func detailed(_ element: DesktopElementInfo) -> DesktopElementInfo {
        var detailed = element
        detailed.label = listLabel(of: element)
        return boundedForOutput(detailed)
    }

    static func projected(_ element: DesktopElementInfo, includeDetails: Bool) -> DesktopElementInfo {
        includeDetails ? detailed(element) : compact(element)
    }

    /// Maximum encoded size of one projected element. This is below the list
    /// budget, leaving room for keys and the other fields of the response.
    static let maximumProjectedElementCharacters = 6_000
    private static let projectedTextCaps = [501, 250, 120, 60, 20, 0]

    /// Bounds only the serialized projection, never the source `element`: refs
    /// and fingerprints are computed from the integral AX attributes before
    /// this function runs. The actual JSON size is measured, so escape-heavy
    /// Unicode cannot bypass the budget as it could with a character-only cap.
    private static func boundedForOutput(_ element: DesktopElementInfo) -> DesktopElementInfo {
        var result = element
        func fits() -> Bool {
            DesktopListPaging.encodedLength(result) <= maximumProjectedElementCharacters
        }
        guard !fits() else { return result }

        // The label repeats title/description/placeholder. Preserve it as value
        // in a compact element that would otherwise lose all of its text.
        let label = result.label
        result.label = nil
        if result.value == nil { result.value = label }
        if fits() { return result }
        result.actions = nil

        func bounded(_ text: String?, cap: Int) -> String? {
            guard let text, cap > 0 else { return nil }
            guard text.count > cap else { return text }
            return cap > 3 ? String(text.prefix(cap - 3)) + "..." : String(text.prefix(cap))
        }
        for cap in projectedTextCaps {
            result.subrole = bounded(result.subrole, cap: cap)
            result.role_description = bounded(result.role_description, cap: cap)
            result.title = bounded(result.title, cap: cap)
            result.description = bounded(result.description, cap: cap)
            result.value = bounded(result.value, cap: cap)
            result.placeholder = bounded(result.placeholder, cap: cap)
            result.app_name = bounded(result.app_name, cap: cap)
            result.window_title = bounded(result.window_title, cap: cap)
            if fits() { return result }
        }
        // Keep ref intact: it is the usable identity of the element. An
        // overlong identifier is omitted rather than returned as a false exact
        // selector; role is required by the model and bounded only as a last resort.
        result.identifier = nil
        if fits() { return result }
        result.role = String(result.role.prefix(64))
        return result
    }

    // MARK: Filters

    static func isInteractive(role: String, subrole: String?, actions: [String], valueSettable: Bool) -> Bool {
        if interactiveRoles.contains(role) { return true }
        if let subrole, interactiveSubroles.contains(subrole) { return true }
        if actions.contains(where: interactiveActions.contains) { return true }
        return valueSettable
    }

    static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let textEntrySubroles: Set<String> = ["AXSearchField", "AXSecureTextField"]

    /// A click is a safe focus fallback only for text-entry elements (text
    /// fields, text areas, combo boxes, search and secure fields). On any other
    /// element, settable or not (a button, checkbox, link, slider, scroll bar,
    /// or stepper), a click would activate or change it rather than focus it.
    static func allowsFocusClickFallback(role: String, subrole: String?) -> Bool {
        if textEntryRoles.contains(role) { return true }
        if let subrole, textEntrySubroles.contains(subrole) { return true }
        return false
    }

    /// Validates a role filter and returns its lowercased form; nil when absent.
    static func normalizedRoleFilter(_ raw: String?) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumRoleFilterCharacters,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
            throw DesktopControlError.invalidArgument(
                "role", "must be an Accessibility role or subrole of at most \(maximumRoleFilterCharacters) letters or digits, such as AXButton or textfield."
            )
        }
        return trimmed.lowercased()
    }

    /// Case-insensitive role/subrole match with an optional AX prefix:
    /// "AXTextField", "textfield", and "TextField" all match AXTextField.
    static func roleMatches(_ filter: String, role: String, subrole: String?) -> Bool {
        let wanted = filter.lowercased()
        return [role, subrole].compactMap { $0?.lowercased() }.contains { candidate in
            candidate == wanted || candidate == "ax" + wanted
        }
    }

    static func validatedQuery(_ raw: String?) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumQueryCharacters else {
            throw DesktopControlError.invalidArgument("query", "must contain at most \(maximumQueryCharacters) characters.")
        }
        return trimmed
    }

    /// Validates an identifier selector: nil when absent or blank, otherwise
    /// the text unchanged, since it is matched exactly and case-sensitively.
    static func validatedIdentifier(_ raw: String?) throws -> String? {
        guard let raw, raw.nilIfBlank != nil else { return nil }
        guard raw.count <= maximumIdentifierCharacters else {
            throw DesktopControlError.invalidArgument("identifier", "must contain at most \(maximumIdentifierCharacters) characters.")
        }
        return raw
    }

    /// Exact, case-sensitive match of an identifier selector on an element's
    /// AXIdentifier; an element without one never matches.
    static func identifierMatches(_ identifier: String, candidate: String?) -> Bool {
        candidate == identifier
    }

    /// The element selectors of an element action, validated.
    struct ElementSelectors: Equatable {
        let reference: String?
        let query: String?
        let identifier: String?

        var isEmpty: Bool { reference == nil && query == nil && identifier == nil }
    }

    /// element_ref alone, or query and identifier (each optional, combinable
    /// with role): element_ref is refused with either of them.
    static func validatedElementSelectors(elementRef: String?, query: String?, identifier: String?) throws -> ElementSelectors {
        let query = try validatedQuery(query)
        let identifier = try validatedIdentifier(identifier)
        let reference = elementRef?.nilIfBlank
        if reference != nil, query != nil || identifier != nil {
            throw DesktopControlError.invalidArgument(
                "element_ref/query/identifier", "pass either element_ref, or query and/or identifier, not both."
            )
        }
        return ElementSelectors(reference: reference, query: query, identifier: identifier)
    }

    /// "query 'Save'", "identifier 'save-button'", or both joined with "and".
    static func selectorPhrase(query: String?, identifier: String?) -> String {
        let parts = [query.map { "query '\($0)'" }, identifier.map { "identifier '\($0)'" }].compactMap { $0 }
        return parts.isEmpty ? "the selectors" : parts.joined(separator: " and ")
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Case- and diacritic-insensitive substring match on the element's texts.
    static func matchesQuery(_ query: String, element: DesktopElementInfo) -> Bool {
        let needle = folded(query)
        guard !needle.isEmpty else { return true }
        return [element.title, element.description, element.value, element.placeholder, element.identifier, element.role_description]
            .compactMap { $0 }
            .contains { folded($0).contains(needle) }
    }

    // MARK: Resolution

    enum Choice: Equatable {
        case unique(Int)
        case ambiguous([Int])
        /// The visit was cut short and the matches found so far hold no single
        /// exact match; candidates are listed exact matches first.
        case incomplete([Int])
        case noMatch
    }

    /// After a complete visit, one match wins outright; among several, a single
    /// case-insensitive exact match on title, description, or placeholder wins;
    /// otherwise ambiguous. After a visit cut short (node or time budget, match
    /// limit), only a single exact match wins: a better match may lie in the
    /// part of the tree that was not visited. Without a query (identifier
    /// alone), every candidate is an exact match, since the identifier is
    /// matched exactly: a single one wins even after a visit cut short.
    static func choose(_ candidates: [DesktopElementInfo], query: String?, visitIsComplete: Bool = true) -> Choice {
        guard !candidates.isEmpty else { return .noMatch }
        if visitIsComplete, candidates.count == 1 { return .unique(0) }
        let exact = candidates.indices.filter { index in
            guard let query else { return true }
            let element = candidates[index]
            return [element.title, element.description, element.placeholder].compactMap { $0 }.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(query) == .orderedSame
            }
        }
        if exact.count == 1 { return .unique(exact[0]) }
        // List exact matches first so the error shows the likeliest targets.
        let ordered = exact + candidates.indices.filter { !exact.contains($0) }
        return visitIsComplete ? .ambiguous(ordered) : .incomplete(ordered)
    }

    static func candidateList(_ candidates: [DesktopElementInfo]) -> String {
        let listed = candidates.prefix(maximumAmbiguityCandidates).map { element in
            describe(element) + (element.ref.map { " (element_ref \($0))" } ?? "")
        }
        let more = candidates.count > maximumAmbiguityCandidates ? "; ..." : ""
        return listed.joined(separator: "; ") + more
    }

    static func ambiguityMessage(query: String?, identifier: String? = nil, candidates: [DesktopElementInfo], scope: String) -> String {
        "\(candidates.count) elements match \(selectorPhrase(query: query, identifier: identifier)) in \(scope): \(candidateList(candidates)). Refine query, identifier, or role, or pass one element_ref."
    }

    /// The error for a query whose visit was cut short without a single exact
    /// match, or an identifier found more than once before the visit stopped;
    /// `truncation` explains where the visit stopped.
    static func incompleteVisitMessage(
        query: String?, identifier: String? = nil, candidates: [DesktopElementInfo], scope: String, truncation: String
    ) -> String {
        let found = "\(candidates.count) element(s) match \(selectorPhrase(query: query, identifier: identifier)) in \(scope) so far"
        let reason = query == nil
            ? ", and the search did not cover the whole window"
            : ", but none is the single exact title, description, or placeholder match required when the search does not cover the whole window"
        return "\(found)\(reason): \(candidateList(candidates)). \(truncation) Narrow the search with role, a window selector (window_id or title), or a lower max_depth, or pass an element_ref from list_elements."
    }

    static func noMatchMessage(query: String?, identifier: String? = nil, role: String?, scope: String, interactiveOnly: Bool) -> String {
        let roleText = role.map { " with role \($0)" } ?? ""
        let hint = interactiveOnly ? " or retry with interactive_only=false" : ""
        return "No element matches \(selectorPhrase(query: query, identifier: identifier))\(roleText) in \(scope). Call list_elements to inspect the window's elements\(hint)."
    }

    /// list_elements and query: some nodes timed out (`.cannotComplete`).
    static func unresponsiveNote(appName: String, nodes: Int) -> String {
        "\(appName) is not responding to Accessibility requests; \(nodes) node(s) could not be read."
    }

    /// list_elements and read_text: the window belongs to the app hosting zen.
    static func hostsZenNote(appLabel: String) -> String {
        "\(appLabel) hosts this zen session: these elements belong to zen's own window, not to the app you may want to control. Select the target with app_name, bundle_id, pid, or window_id."
    }

    // MARK: set_value

    /// After a write, the value is re-read at this interval, up to the budget,
    /// while it still reads back as before: some apps apply it a moment later.
    static let setValueReadBackInterval: Duration = .milliseconds(75)
    static let setValueReadBackBudget: Duration = .milliseconds(500)

    enum SetValueOutcome: Equatable {
        case applied
        /// The value reads back unchanged from before the write.
        case notApplied
        /// The app stored a different text (reformatted, filtered, truncated).
        case changed(readBack: String)
    }

    /// Compares the value read back after set_value with the requested text and
    /// the value before the write; a value that cannot be read counts as empty.
    static func setValueOutcome(requested: String, before: String?, after: String?) -> SetValueOutcome {
        let after = after ?? ""
        if after == requested { return .applied }
        if after == (before ?? "") { return .notApplied }
        return .changed(readBack: after)
    }

    static let maximumReadBackPreviewCharacters = 80

    /// A one-line preview of a read-back value, at most 80 characters.
    static func readBackPreview(_ text: String) -> String {
        let singleLine = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        guard singleLine.count > maximumReadBackPreviewCharacters else { return singleLine }
        return String(singleLine.prefix(maximumReadBackPreviewCharacters - 3)) + "..."
    }

    static func changedValueNote(element: String, readBack: String) -> String {
        "\(element) reads back '\(readBackPreview(readBack))' instead of the requested text; the app may have reformatted, filtered, or truncated it."
    }

    /// The error when the value still reads back as before after the polling
    /// budget. The write may land late, so the caller must re-read first.
    static func valueNotAppliedMessage(element: String) -> String {
        "Value not applied: \(element) still reads back its previous value, although the app may still apply it late. Re-read the value with list_elements before using focus_element and type_text, so the text is not typed twice."
    }

    /// set_value timed out (`.cannotComplete`): the write may have been applied.
    static let valueUnconfirmedNote = "The app did not confirm the write before the Accessibility timeout; the value may have been applied, so re-read it with list_elements before retrying."

    // MARK: Argument validation

    /// scroll, drag, and move_mouse work on coordinates and never on elements,
    /// like press_key: element_ref, query, and identifier are refused.
    static func validatePointerAction(_ action: String, elementRef: String?, query: String?, identifier: String? = nil) throws {
        guard elementRef?.nilIfBlank == nil, query?.nilIfBlank == nil, identifier?.nilIfBlank == nil else {
            throw DesktopControlError.invalidArgument(
                "element_ref/query/identifier",
                "\(action) does not target elements; pass coordinates instead (for example the center of an element from list_elements)."
            )
        }
    }

    /// An element_ref already identifies its window: title and window_index
    /// are refused with it. (window_id and the app selectors are checked
    /// against the reference.)
    static func validateReferenceSelectors(title: String?, windowIndex: Int?) throws {
        if title?.nilIfBlank != nil {
            throw DesktopControlError.invalidArgument("title", "must be omitted with element_ref, which already identifies its window.")
        }
        if windowIndex != nil {
            throw DesktopControlError.invalidArgument("window_index", "must be omitted with element_ref, which already identifies its window.")
        }
    }

    // MARK: Window stacking

    /// Before refusing a click as covered, the hit test is repeated: a window
    /// still animating or a tooltip may be passing over the element.
    static let topmostAttempts = 3
    static let topmostRetryDelay: Duration = .milliseconds(100)

    struct StackedWindow: Equatable {
        let pid: Int32
        let appName: String?
        let bounds: CGRect
        let alpha: Double
        let layer: Int
    }

    /// The front-most visible normal window (layer 0) containing `point`, given
    /// windows in front-to-back order. Windows on other layers (overlays, the
    /// menu bar, floating panels) are ignored to avoid false positives.
    static func topmostWindow(at point: CGPoint, in windows: [StackedWindow]) -> StackedWindow? {
        windows.first { $0.layer == 0 && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// The error when the element at a click point is not the target or one of
    /// its descendants.
    static func coveredMessage(target: String, point: String, cover: String, coverApp: String, targetApp: String) -> String {
        "The center of \(target) at \(point) is covered by \(cover) of \(coverApp); no click was sent. Bring \(targetApp) to the front with activate_app or focus_window, close what covers the element, or scroll it into view, then retry."
    }
}

/// Refuses input that would land in the app hosting this zen session unless
/// the caller selected that app explicitly and exactly: by pid, by bundle_id,
/// or by its whole app_name (case-insensitive). A partial app_name, element_ref,
/// query, title, and window_id never authorize the host.
enum DesktopHostInputPolicy {
    enum Decision: Equatable {
        case allow
        case refuse
        /// The selectors reach the host only through a partial app_name.
        case refuseInexactSelection
    }

    enum Kind: Equatable {
        case typeText
        case pressKey
        case pressElement
        case focusElement
        case setValue
        /// type_text aimed at an element through element_ref or query.
        case typeIntoElement
        /// click aimed at an element through element_ref or query.
        case clickElement
        /// close_window on a window of the host.
        case closeWindow
    }

    /// The app chosen by pid, bundle_id, or app_name, and whether the
    /// selectors name it exactly (`isExactSelection`).
    struct Selection: Equatable {
        let pid: Int32
        let isExact: Bool
    }

    static func decide(targetPID: Int32?, hostPID: Int32?, selection: Selection?) -> Decision {
        guard let hostPID, let targetPID, targetPID == hostPID else { return .allow }
        guard let selection, selection.pid == hostPID else { return .refuse }
        return selection.isExact ? .allow : .refuseInexactSelection
    }

    /// Whether the selectors name the app exactly, with the precedence of
    /// `matchingRunningApp`: the pid, else the bundle_id compared without case,
    /// else the whole app_name compared without case. A partial name never counts.
    static func isExactSelection(
        pid: Int32?, bundleID: String?, appName: String?,
        appPID: Int32, appBundleID: String?, appLocalizedName: String?
    ) -> Bool {
        if let pid { return pid == appPID }
        if let bundleID = bundleID?.nilIfBlank {
            return appBundleID?.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        if let appName = appName?.nilIfBlank {
            return appLocalizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }
        return false
    }

    private static func elementVerb(_ kind: Kind) -> String? {
        switch kind {
        case .pressElement: return "press"
        case .focusElement: return "focus"
        case .setValue: return "set the value of"
        case .typeIntoElement: return "type into"
        case .clickElement: return "click"
        case .typeText, .pressKey, .closeWindow: return nil
        }
    }

    /// "type", "press keys", "click the element", "close the window".
    private static func refusedAction(_ kind: Kind) -> String {
        switch kind {
        case .typeText: return "type"
        case .pressKey: return "press keys"
        case .closeWindow: return "close the window"
        default: return "\(elementVerb(kind) ?? "use") the element"
        }
    }

    static func refusalMessage(_ kind: Kind, appName: String) -> String {
        let hosting = "\(appName), the application hosting this zen session, so the input would go into zen itself."
        let onPurpose = "pass its exact app_name, its bundle_id, or its pid."
        switch kind {
        case .typeText:
            return "Refusing to type: keyboard focus is in \(hosting) Activate the target app first (activate_app, focus_window, or pass app_name/bundle_id/pid, element_ref, or query), then retry. To type into \(appName) on purpose, \(onPurpose)"
        case .pressKey:
            return "Refusing to press keys: keyboard focus is in \(hosting) Activate the target app first (activate_app, focus_window, focus_element, or pass app_name/bundle_id/pid), then retry; to switch apps, use activate_app rather than a shortcut such as command+tab. To press keys in \(appName) on purpose, \(onPurpose)"
        case .closeWindow:
            return "Refusing to close the window: it belongs to \(appName), the application hosting this zen session, so closing it could end zen itself. To close another app's window, select it with window_id from list_windows (hosts_zen marks the host's windows). To close a window of \(appName) on purpose, \(onPurpose)"
        case .pressElement, .focusElement, .setValue, .typeIntoElement, .clickElement:
            let verb = elementVerb(kind) ?? "use"
            return "Refusing to \(verb) the element: it belongs to \(hosting) Select the target app's window first (list_elements or query with app_name/bundle_id/pid or window_id), then retry with its element_ref. To \(verb) an element of \(appName) on purpose, \(onPurpose)"
        }
    }

    /// The refusal when app_name reaches the host only as a partial match.
    static func inexactSelectionMessage(_ kind: Kind, appName: String, selector: String) -> String {
        "Refusing to \(refusedAction(kind)): app_name '\(selector)' matches \(appName), the application hosting this zen session, only partially. To act on \(appName) on purpose, pass its exact app_name ('\(appName)'), its bundle_id, or its pid; to target another app, pass that app's exact name."
    }

    enum LandingEvent: String {
        case click
        case scroll
        case drag
    }

    /// The note added (without refusing) when a coordinate click, a scroll, or
    /// the end of a drag lands on the app hosting zen.
    static func landingNote(_ event: LandingEvent, appName: String) -> String {
        let landed = event == .drag ? "The drag ended on" : "The \(event.rawValue) landed on"
        return "\(landed) \(appName), which hosts this zen session; the intended window may be behind it. Activate the target app or use list_elements."
    }
}
