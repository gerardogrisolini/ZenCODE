import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ToolCore

/// Live Accessibility reads for element actions. Everything here only gathers
/// attributes; filtering, matching, and refs are decided by the pure
/// `DesktopElementPolicy` and `DesktopElementReference` types.
extension DesktopController {
    static let elementMessagingTimeout: Float = 1
    static let elementNodeBudget = DesktopElementPolicy.visitNodeBudget
    static let elementTimeBudget = DesktopElementPolicy.visitTimeBudget
    static let maximumResolutionMatches = 500
    static let maximumActionNames = 32

    /// The app and window that own a set of elements, plus the anchor used to
    /// encode refs (nil when the window cannot be anchored).
    struct ElementScope {
        let pid: pid_t
        let appName: String?
        let window: AXUIElement?
        let windowTitle: String?
        let anchor: DesktopElementReference.WindowAnchor?
        let hostsZen: Bool

        var appLabel: String { appName ?? "pid \(pid)" }

        /// "window 'Project' of Final Cut Pro".
        var phrase: String {
            if let windowTitle { return "window '\(windowTitle)' of \(appLabel)" }
            return window == nil ? appLabel : "the untitled window of \(appLabel)"
        }
    }

    struct ResolvedElement {
        let element: AXUIElement
        let info: DesktopElementInfo
        let scope: ElementScope
        let path: [Int]?
        /// True when an element_ref was relocated in its window
        /// (`relocateReference`): `info.ref` is the new reference.
        var relocated = false
        var pid: pid_t { scope.pid }
        var phrase: String { DesktopElementPolicy.locationPhrase(info) }
        var relocationNote: String? { relocated ? DesktopElementReference.relocationNote : nil }
    }

    struct ElementVisit {
        var matches: [ResolvedElement] = []
        var visited = 0
        /// Nodes skipped because the app did not answer (`.cannotComplete`).
        var unresponsiveNodes = 0
        var stoppedByNodeBudget = false
        var stoppedByTimeBudget = false
        var stoppedByLimit = false

        /// False when the visit stopped early (node or time budget, match
        /// limit) or skipped nodes that did not answer.
        var isComplete: Bool {
            !stoppedByNodeBudget && !stoppedByTimeBudget && !stoppedByLimit && unresponsiveNodes == 0
        }

        var budgetNote: String? {
            if stoppedByTimeBudget {
                return "The Accessibility tree visit stopped at the \(Int(DesktopElementPolicy.visitTimeBudget))-second time budget after \(visited) node(s), so results may be incomplete; narrow it with query, role, or max_depth."
            }
            if stoppedByNodeBudget {
                return "The Accessibility tree visit stopped at the \(DesktopElementPolicy.visitNodeBudget)-node budget, so results may be incomplete; narrow it with query, role, or max_depth."
            }
            return nil
        }

        /// Why the visit of a query is incomplete, for resolution errors.
        func truncationNote(limit: Int, appName: String) -> String {
            var notes: [String] = []
            if let budgetNote { notes.append(budgetNote) }
            if stoppedByLimit { notes.append("The visit stopped after \(limit) matching elements.") }
            if unresponsiveNodes > 0 {
                notes.append(DesktopElementPolicy.unresponsiveNote(appName: appName, nodes: unresponsiveNodes))
            }
            return notes.joined(separator: " ")
        }
    }

    struct AXSnapshot {
        var role: String?
        var subrole: String?
        var roleDescription: String?
        var title: String?
        var description: String?
        var placeholder: String?
        var identifier: String?
        var enabled: Bool?
        var focused: Bool?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    enum AXSnapshotRead {
        case snapshot(AXSnapshot)
        /// The element no longer exists (`.invalidUIElement`).
        case gone
        /// The app did not answer within the messaging timeout (`.cannotComplete`).
        case unresponsive
    }

    private static let snapshotAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXChildrenAttribute
    ]

    // MARK: Attribute reads

    /// Bounds every AX request of this one-shot worker so a slow or hung app
    /// cannot stall the call: globally (system-wide element) and for `application`.
    static func prepareAXMessaging(_ application: AXUIElement? = nil) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), elementMessagingTimeout)
        if let application {
            AXUIElementSetMessagingTimeout(application, elementMessagingTimeout)
        }
    }

    /// Reads the descriptive attributes of an element in one round trip; nil
    /// when it no longer exists or does not answer.
    static func axSnapshot(_ element: AXUIElement) -> AXSnapshot? {
        guard case let .snapshot(snapshot) = readAXSnapshot(element) else { return nil }
        return snapshot
    }

    /// Reads the descriptive attributes of an element in one round trip,
    /// telling a vanished element apart from one whose app does not answer.
    static func readAXSnapshot(_ element: AXUIElement) -> AXSnapshotRead {
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element, snapshotAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        )
        var values: [AnyObject?]
        if result == .success, let raw, CFArrayGetCount(raw) == snapshotAttributes.count {
            values = (raw as NSArray).map { item -> AnyObject? in
                let object = item as AnyObject
                if CFGetTypeID(object) == AXValueGetTypeID(), AXValueGetType(object as! AXValue) == .axError {
                    return nil
                }
                return object
            }
        } else if result == .invalidUIElement {
            return .gone
        } else if result == .cannotComplete {
            return .unresponsive
        } else {
            values = snapshotAttributes.map { copyAXRaw(element, attribute: $0 as CFString) as AnyObject? }
        }

        func point(_ object: AnyObject?) -> CGPoint? {
            guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            return AXValueGetValue(object as! AXValue, .cgPoint, &point) ? point : nil
        }
        func size(_ object: AnyObject?) -> CGSize? {
            guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(object as! AXValue, .cgSize, &size) ? size : nil
        }

        var snapshot = AXSnapshot()
        snapshot.role = values[0] as? String
        snapshot.subrole = values[1] as? String
        snapshot.roleDescription = DesktopElementPolicy.textValue(values[2])
        snapshot.title = DesktopElementPolicy.textValue(values[3])
        snapshot.description = DesktopElementPolicy.textValue(values[4])
        snapshot.placeholder = DesktopElementPolicy.textValue(values[5])
        snapshot.identifier = DesktopElementPolicy.textValue(values[6])
        snapshot.enabled = (values[7] as? NSNumber)?.boolValue
        snapshot.focused = (values[8] as? NSNumber)?.boolValue
        if let origin = point(values[9]), let extent = size(values[10]) {
            snapshot.frame = CGRect(origin: origin, size: extent)
        }
        snapshot.children = values[11] as? [AXUIElement] ?? []
        return .snapshot(snapshot)
    }

    static func axActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] else { return [] }
        return Array(names.prefix(maximumActionNames))
    }

    static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// The element's value as text, never for secure fields. Long text areas
    /// (a terminal scrollback, a document) are read only up to the reported
    /// bound; `limit` is the characters kept (200 for list_elements, one more
    /// than a text for read_text).
    static func axDisplayValue(
        _ element: AXUIElement, role: String, subrole: String?, limit: Int = DesktopElementPolicy.maximumValueCharacters
    ) -> String? {
        guard !DesktopElementPolicy.isSecure(role: role, subrole: subrole) else { return nil }
        if role == kAXTextAreaRole,
           let length = (copyAXRaw(element, attribute: kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue,
           length > 4 * limit {
            var range = CFRange(location: 0, length: limit + 1)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var raw: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw
            ) == .success else {
                return nil
            }
            return DesktopElementPolicy.textValue(raw)
        }
        return DesktopElementPolicy.textValue(copyAXRaw(element, attribute: kAXValueAttribute as CFString))
    }

    static func elementPID(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    static func makeElementInfo(
        _ element: AXUIElement,
        snapshot: AXSnapshot,
        role: String,
        actions: [String],
        valueSettable: Bool,
        scope: ElementScope,
        path: [Int]?,
        valueLimit: Int = DesktopElementPolicy.maximumValueCharacters
    ) -> DesktopElementInfo {
        var info = DesktopElementPolicy.makeInfo(
            role: role,
            subrole: snapshot.subrole,
            roleDescription: snapshot.roleDescription,
            title: snapshot.title,
            description: snapshot.description,
            value: axDisplayValue(element, role: role, subrole: snapshot.subrole, limit: valueLimit),
            placeholder: snapshot.placeholder,
            identifier: snapshot.identifier,
            enabled: snapshot.enabled,
            focused: snapshot.focused,
            valueSettable: valueSettable,
            frame: snapshot.frame,
            actions: actions,
            pid: scope.pid,
            appName: scope.appName,
            windowTitle: scope.windowTitle,
            hostsZen: scope.hostsZen,
            valueLimit: valueLimit
        )
        if let path, let anchor = scope.anchor {
            info.ref = DesktopElementReference(
                pid: scope.pid, window: anchor, path: path, role: role,
                fingerprint: DesktopElementReference.fingerprint(of: info)
            ).encoded
        }
        return info
    }

    /// Re-reads an element; nil once it no longer exists.
    static func describeElement(_ element: AXUIElement, scope: ElementScope, path: [Int]?) -> DesktopElementInfo? {
        guard let snapshot = axSnapshot(element), let role = snapshot.role else { return nil }
        return makeElementInfo(
            element, snapshot: snapshot, role: role, actions: axActions(element),
            valueSettable: isValueSettable(element), scope: scope, path: path
        )
    }

    // MARK: Windows and scopes

    static func hasAppSelectors(_ input: DesktopRunInput) -> Bool {
        input.pid != nil || input.bundle_id?.nilIfBlank != nil || input.app_name?.nilIfBlank != nil
    }

    static func hasWindowSelectors(_ input: DesktopRunInput) -> Bool {
        input.window_id != nil || input.window_index != nil || input.title?.nilIfBlank != nil
    }

    static func hasElementSelectors(_ input: DesktopRunInput) -> Bool {
        input.element_ref?.nilIfBlank != nil || input.query?.nilIfBlank != nil || input.identifier?.nilIfBlank != nil
    }

    /// The window searched by list_elements and query: the window selectors of
    /// the window actions when present, otherwise the focused, main, or first
    /// window of the frontmost app.
    static func elementWindowSelection(_ input: DesktopRunInput) throws -> AXWindowSelection {
        try requireAccessibility()
        if hasAppSelectors(input) || hasWindowSelectors(input) {
            let selection = try selectedAXWindow(input)
            prepareAXMessaging(AXUIElementCreateApplication(selection.pid))
            return selection
        }
        guard let frontmost = currentFrontmostApplication() else { throw DesktopControlError.appNotFound }
        let pid = frontmost.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        prepareAXMessaging(application)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            do {
                return try AXWindowSelection(
                    element: copyAXElement(application, attribute: attribute as CFString, operation: "read window"),
                    pid: pid, expected: nil
                )
            } catch let DesktopControlError.accessibilityFailed(operation, error) {
                switch error {
                case .noValue, .attributeUnsupported, .invalidUIElement:
                    continue
                case .cannotComplete:
                    throw DesktopControlError.applicationNotResponding(
                        frontmost.localizedName ?? frontmost.bundleIdentifier ?? "pid \(pid)"
                    )
                default:
                    throw DesktopControlError.accessibilityFailed(operation, error)
                }
            }
        }
        var rawWindows: CFTypeRef?
        switch AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) {
        case .success:
            if let first = (rawWindows as? [AXUIElement])?.first {
                return AXWindowSelection(element: first, pid: pid, expected: nil)
            }
        case .noValue, .attributeUnsupported:
            break
        case .cannotComplete:
            throw DesktopControlError.applicationNotResponding(
                frontmost.localizedName ?? frontmost.bundleIdentifier ?? "pid \(pid)"
            )
        case let error:
            throw DesktopControlError.accessibilityFailed("read windows", error)
        }
        throw DesktopControlError.windowNotFound
    }

    static func axWindowIndex(_ window: AXUIElement, pid: pid_t) -> Int? {
        guard let windows = copyAXRaw(AXUIElementCreateApplication(pid), attribute: kAXWindowsAttribute as CFString) as? [AXUIElement],
              let index = windows.firstIndex(where: { CFEqual($0, window) }),
              index <= DesktopElementReference.maximumWindowIndex else {
            return nil
        }
        return index
    }

    /// Reads a title, telling a failed read (timeout or AX error) from a window
    /// that has no title (`.noValue`, `.attributeUnsupported`).
    static func readAXTitle(_ element: AXUIElement) -> (title: String?, failed: Bool) {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw) {
        case .success: return (raw as? String, false)
        case .noValue, .attributeUnsupported: return (nil, false)
        default: return (nil, true)
        }
    }

    static func elementScope(for selection: AXWindowSelection) -> (scope: ElementScope, window: DesktopWindowInfo) {
        let windowInfo = axWindowInfo(selection)
        let anchor: DesktopElementReference.WindowAnchor?
        if let windowID = windowInfo.window_id {
            anchor = .windowID(windowID)
        } else if let index = axWindowIndex(selection.element, pid: selection.pid) {
            // A title that could not be read leaves the window unanchored (no
            // refs) instead of claiming that it is untitled.
            let read = readAXTitle(selection.element)
            anchor = DesktopElementReference.indexAnchor(index: index, title: read.title, titleReadFailed: read.failed)
        } else {
            anchor = nil
        }
        let scope = ElementScope(
            pid: selection.pid,
            appName: NSRunningApplication(processIdentifier: selection.pid)?.localizedName ?? windowInfo.app_name,
            window: selection.element,
            windowTitle: windowInfo.title,
            anchor: anchor,
            hostsZen: DesktopHostApplication.current()?.pid == selection.pid
        )
        return (scope, windowInfo)
    }

    static func appOnlyScope(pid: pid_t) -> ElementScope {
        ElementScope(
            pid: pid,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            window: nil,
            windowTitle: nil,
            anchor: nil,
            hostsZen: DesktopHostApplication.current()?.pid == pid
        )
    }

    // MARK: Tree visit

    /// Depth-first, in child order, below the scope's window. Bounded by
    /// `maxDepth`, the node budget, the time budget, and `limit` matches.
    /// `identifier` keeps only the elements whose AXIdentifier is exactly it.
    /// `relocating` keeps only the elements with the role and fingerprint of
    /// that reference, and also those without an on-screen frame, so that a
    /// relocation counts every element that could be the reference's.
    /// `includeFrameless` also keeps elements without a positive on-screen frame
    /// (read_text, whose text remains useful off screen or when AX has no frame).
    /// `timeBudget` is the seconds the visit may take; wait_for shortens it to
    /// the time it has left. `valueLimit` is the characters kept of each returned
    /// value (read_text reads more than the 200 of list_elements); query matching
    /// reads the full AX value separately, so the output cap cannot hide a match.
    static func visitElements(
        in scope: ElementScope,
        maxDepth: Int,
        interactiveOnly: Bool,
        roleFilter: String?,
        query: String?,
        identifier: String? = nil,
        relocating reference: DesktopElementReference? = nil,
        timeBudget: Double = DesktopElementPolicy.visitTimeBudget,
        valueLimit: Int = DesktopElementPolicy.maximumValueCharacters,
        includeFrameless: Bool = false,
        limit: Int
    ) -> ElementVisit {
        var visit = ElementVisit()
        guard let window = scope.window else { return visit }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeBudget))
        var stack: [(element: AXUIElement, path: [Int], depth: Int)] = []
        func push(_ children: [AXUIElement], parentPath: [Int], depth: Int) {
            for (index, child) in children.enumerated().reversed() where index <= DesktopElementReference.maximumChildIndex {
                stack.append((child, parentPath + [index], depth))
            }
        }
        var rootChildren: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &rootChildren) == .cannotComplete {
            visit.unresponsiveNodes += 1
        }
        push(rootChildren as? [AXUIElement] ?? [], parentPath: [], depth: 1)

        while let node = stack.popLast() {
            if visit.visited >= elementNodeBudget { visit.stoppedByNodeBudget = true; break }
            if clock.now >= deadline { visit.stoppedByTimeBudget = true; break }
            visit.visited += 1
            let snapshot: AXSnapshot
            switch readAXSnapshot(node.element) {
            case let .snapshot(read): snapshot = read
            case .gone: continue
            case .unresponsive:
                visit.unresponsiveNodes += 1
                continue
            }
            if node.depth < maxDepth {
                push(snapshot.children, parentPath: node.path, depth: node.depth + 1)
            }
            guard let role = snapshot.role else { continue }
            if let reference {
                // The fingerprint of the snapshot equals that of its element
                // info: blank texts count as absent in both.
                guard role == reference.role,
                      DesktopElementReference.fingerprint(
                          role: role, subrole: snapshot.subrole, title: snapshot.title,
                          description: snapshot.description, identifier: snapshot.identifier
                      ) == reference.fingerprint else { continue }
            } else if !includeFrameless {
                guard let frame = snapshot.frame, DesktopElementPolicy.isPositive(frame) else { continue }
            }
            if let roleFilter, !DesktopElementPolicy.roleMatches(roleFilter, role: role, subrole: snapshot.subrole) { continue }
            // Checked on the snapshot, before the actions are read: the info
            // keeps a non-blank AXIdentifier unchanged.
            if let identifier, !DesktopElementPolicy.identifierMatches(identifier, candidate: snapshot.identifier) { continue }
            let actions = axActions(node.element)
            let settable = isValueSettable(node.element)
            if interactiveOnly,
               !DesktopElementPolicy.isInteractive(role: role, subrole: snapshot.subrole, actions: actions, valueSettable: settable) {
                continue
            }
            let info = makeElementInfo(
                node.element, snapshot: snapshot, role: role, actions: actions,
                valueSettable: settable, scope: scope, path: node.path, valueLimit: valueLimit
            )
            if let query {
                var matchInfo = info
                // Matching uses the full AX value, while the returned info keeps
                // its bounded value. Otherwise text beyond the output cap would
                // be invisible and element_absent could be confirmed incorrectly.
                if !DesktopElementPolicy.isSecure(role: role, subrole: snapshot.subrole),
                   let fullValue = DesktopElementPolicy.textValue(
                       copyAXRaw(node.element, attribute: kAXValueAttribute as CFString)
                   ) {
                    matchInfo.value = fullValue
                }
                guard DesktopElementPolicy.matchesQuery(query, element: matchInfo) else { continue }
            }
            visit.matches.append(ResolvedElement(element: node.element, info: info, scope: scope, path: node.path))
            if visit.matches.count >= limit {
                visit.stoppedByLimit = !stack.isEmpty
                break
            }
        }
        return visit
    }

    // MARK: Resolution

    /// What a look-up of an element_ref found.
    enum ReferenceLookup {
        case found(ResolvedElement)
        /// The reference leads to no element. `visitIsComplete` is true when
        /// that is certain: its app or window is gone, or a complete search of
        /// its window found no element with its role and fingerprint. It is
        /// false when something could not be read, the search was cut short or
        /// skipped nodes that did not answer, or elements were found that
        /// cannot be taken for the reference's.
        case gone(visitIsComplete: Bool)
    }

    static func resolveReference(_ reference: DesktopElementReference) throws -> ResolvedElement {
        guard case let .found(resolved) = try lookUpReference(reference) else {
            throw DesktopControlError.staleElementReference
        }
        return resolved
    }

    /// Looks the element of a reference up: at its path, else relocated in its
    /// window. Throws when the app does not answer. `visitBudget` is the
    /// seconds the relocation search may take.
    static func lookUpReference(
        _ reference: DesktopElementReference, visitBudget: Double = DesktopElementPolicy.visitTimeBudget
    ) throws -> ReferenceLookup {
        guard let app = NSRunningApplication(processIdentifier: reference.pid), !app.isTerminated else {
            return .gone(visitIsComplete: true)
        }
        let appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(reference.pid)"
        let application = AXUIElementCreateApplication(reference.pid)
        prepareAXMessaging(application)
        /// Tells a timeout (the app does not answer) apart from a missing value.
        func read(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
            if result == .cannotComplete { throw DesktopControlError.applicationNotResponding(appName) }
            return result == .success ? raw : nil
        }

        let window: AXUIElement
        switch reference.window {
        case let .windowID(windowID):
            let selection: AXWindowSelection
            do {
                selection = try selectedAXWindow(DesktopRunInput(action: "list_elements", window_id: windowID))
            } catch let DesktopControlError.accessibilityFailed(_, error) where error == .cannotComplete {
                throw DesktopControlError.applicationNotResponding(appName)
            } catch DesktopControlError.windowNotFound {
                return .gone(visitIsComplete: true)
            } catch {
                return .gone(visitIsComplete: false)
            }
            guard selection.pid == reference.pid else { return .gone(visitIsComplete: true) }
            window = selection.element
        case let .windowIndex(index, titlePrefix):
            guard let windows = try read(application, kAXWindowsAttribute) as? [AXUIElement] else {
                return .gone(visitIsComplete: false)
            }
            let titles = try windows.map { try read($0, kAXTitleAttribute) as? String }
            guard let resolved = DesktopElementReference.resolveWindowIndex(titles: titles, index: index, titlePrefix: titlePrefix) else {
                return .gone(visitIsComplete: true)
            }
            window = windows[resolved]
        }

        // The element may be served by another process than its window's app
        // (web content of Safari or WKWebView, the Open and Save panels): the
        // window's pid is what the reference recorded, and the path from the
        // window and the fingerprint still pin the element down. A window of
        // another process is never searched, so never relocated into.
        guard let windowPID = elementPID(window) else { return .gone(visitIsComplete: false) }
        guard windowPID == reference.pid else { return .gone(visitIsComplete: true) }
        if let resolved = try elementAtPath(of: reference, in: window, read: read, appName: appName) {
            return .found(resolved)
        }
        return relocateReference(reference, in: window, timeBudget: visitBudget)
    }

    /// The element at the reference's path below `window`, nil when the path
    /// no longer leads to it: an index is missing, the element is gone, or its
    /// role or fingerprint differ. Throws when the app does not answer.
    private static func elementAtPath(
        of reference: DesktopElementReference,
        in window: AXUIElement,
        read: (AXUIElement, String) throws -> CFTypeRef?,
        appName: String
    ) throws -> ResolvedElement? {
        var current = window
        for index in reference.path {
            guard let children = try read(current, kAXChildrenAttribute) as? [AXUIElement],
                  children.indices.contains(index) else {
                return nil
            }
            current = children[index]
        }
        let snapshot: AXSnapshot
        switch readAXSnapshot(current) {
        case let .snapshot(read): snapshot = read
        case .gone: return nil
        case .unresponsive: throw DesktopControlError.applicationNotResponding(appName)
        }
        guard snapshot.role == reference.role else { return nil }
        let scope = elementScope(for: AXWindowSelection(element: window, pid: reference.pid, expected: nil)).scope
        let info = makeElementInfo(
            current, snapshot: snapshot, role: reference.role, actions: axActions(current),
            valueSettable: isValueSettable(current), scope: scope, path: reference.path
        )
        // The same path may now lead to another element (siblings inserted or
        // removed, or the element changed): only the recorded one is accepted.
        guard DesktopElementReference.fingerprint(of: info) == reference.fingerprint else { return nil }
        return ResolvedElement(element: current, info: info, scope: scope, path: reference.path)
    }

    /// The element of a reference whose path no longer leads to it, searched
    /// in the same window only, with the usual node and time budgets and
    /// without the interactive filter, among the elements with the reference's
    /// role and fingerprint (`DesktopElementReference.relocation`). The visit
    /// stops at a second match, which makes the reference stale anyway. Without
    /// a relocation the reference is gone only when the visit was complete and
    /// found no element at all with its role and fingerprint.
    private static func relocateReference(
        _ reference: DesktopElementReference, in window: AXUIElement, timeBudget: Double
    ) -> ReferenceLookup {
        let scope = elementScope(for: AXWindowSelection(element: window, pid: reference.pid, expected: nil)).scope
        let visit = visitElements(
            in: scope, maxDepth: DesktopElementReference.maximumPathDepth, interactiveOnly: false,
            roleFilter: nil, query: nil, relocating: reference, timeBudget: timeBudget, limit: 2
        )
        guard case let .relocated(index) = DesktopElementReference.relocation(
            of: reference, candidates: visit.matches.map(\.info), visitIsComplete: visit.isComplete
        ) else {
            return .gone(visitIsComplete: visit.isComplete && visit.matches.isEmpty)
        }
        var match = visit.matches[index]
        match.relocated = true
        return .found(match)
    }

    /// Checks that the selectors of an element action fit the element_ref: no
    /// title or window_index, an app selector that selects the app that owns
    /// it, a window_id that is its window.
    static func validateReference(_ reference: DesktopElementReference, against input: DesktopRunInput) throws {
        try DesktopElementPolicy.validateReferenceSelectors(title: input.title, windowIndex: input.window_index)
        if hasAppSelectors(input) {
            guard let app = matchingRunningApp(input, defaultToFrontmost: false) else { throw DesktopControlError.appNotFound }
            guard app.processIdentifier == reference.pid else {
                throw DesktopControlError.invalidArgument(
                    "pid/bundle_id/app_name", "must select the application that owns element_ref, or be omitted."
                )
            }
        }
        if let windowID = input.window_id {
            guard case let .windowID(anchorID) = reference.window, anchorID == windowID else {
                throw DesktopControlError.invalidArgument("window_id", "must match the window of element_ref, or be omitted.")
            }
        }
    }

    /// Resolves the target of an element action from element_ref, or from
    /// query and identifier (each optional, with an optional role) in the
    /// selected window. A relocated element_ref comes back with `relocated`.
    static func resolveElementTarget(_ input: DesktopRunInput, action: String) throws -> ResolvedElement {
        try requireAccessibility()
        prepareAXMessaging()
        let selectors = try DesktopElementPolicy.validatedElementSelectors(
            elementRef: input.element_ref, query: input.query, identifier: input.identifier
        )

        if let rawReference = selectors.reference {
            let reference = try DesktopElementReference(parsing: rawReference)
            try validateReference(reference, against: input)
            return try resolveReference(reference)
        }

        guard !selectors.isEmpty else { throw DesktopControlError.missingArgument("element_ref, query, or identifier", action) }
        let query = selectors.query
        let identifier = selectors.identifier
        let roleFilter = try DesktopElementPolicy.normalizedRoleFilter(input.role)
        let maxDepth = try boundedInteger(input.max_depth ?? 30, name: "max_depth", range: 1...60)
        let interactiveOnly = input.interactive_only ?? true
        let selection: AXWindowSelection
        do {
            selection = try elementWindowSelection(input)
        } catch let DesktopControlError.accessibilityFailed(_, error) where error == .cannotComplete {
            throw DesktopControlError.applicationNotResponding(selectedApplicationLabel(input))
        }
        let scope = elementScope(for: selection).scope
        let visit = visitElements(
            in: scope, maxDepth: maxDepth, interactiveOnly: interactiveOnly,
            roleFilter: roleFilter, query: query, identifier: identifier, limit: maximumResolutionMatches
        )
        let candidates = visit.matches.map(\.info)
        switch DesktopElementPolicy.choose(candidates, query: query, visitIsComplete: visit.isComplete) {
        case let .unique(index):
            return visit.matches[index]
        case let .ambiguous(indices):
            throw DesktopControlError.operationFailed(DesktopElementPolicy.ambiguityMessage(
                query: query, identifier: identifier, candidates: indices.map { candidates[$0] }, scope: scope.phrase
            ))
        case let .incomplete(indices):
            throw DesktopControlError.operationFailed(
                DesktopElementPolicy.incompleteVisitMessage(
                    query: query, identifier: identifier, candidates: indices.map { candidates[$0] }, scope: scope.phrase,
                    truncation: visit.truncationNote(limit: maximumResolutionMatches, appName: scope.appLabel)
                )
            )
        case .noMatch:
            let message = DesktopElementPolicy.noMatchMessage(
                query: query, identifier: identifier, role: input.role?.nilIfBlank,
                scope: scope.phrase, interactiveOnly: interactiveOnly
            )
            let truncation = visit.isComplete ? "" : " " + visit.truncationNote(limit: maximumResolutionMatches, appName: scope.appLabel)
            throw DesktopControlError.operationFailed(message + truncation)
        }
    }

    // MARK: Live elements (hit test and focus)

    /// The window containing `element` and the child-index path down to it,
    /// climbing kAXParent; the path is nil when an index cannot be verified.
    static func ancestry(of element: AXUIElement) -> (window: AXUIElement?, path: [Int]?) {
        var reversedPath: [Int] = []
        var pathIsValid = true
        var current = element
        for _ in 0...DesktopElementReference.maximumPathDepth {
            let role = copyAXString(current, attribute: kAXRoleAttribute as CFString)
            if role == kAXWindowRole {
                return (current, pathIsValid ? Array(reversedPath.reversed()) : nil)
            }
            if role == kAXApplicationRole { break }
            guard let parent = try? copyAXElement(current, attribute: kAXParentAttribute as CFString, operation: "read parent") else {
                break
            }
            if pathIsValid {
                if let children = copyAXRaw(parent, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement],
                   let index = children.firstIndex(where: { CFEqual($0, current) }) {
                    reversedPath.append(index)
                } else {
                    pathIsValid = false
                }
            }
            current = parent
        }
        let window = try? copyAXElement(element, attribute: kAXWindowAttribute as CFString, operation: "read window")
        return (window, nil)
    }

    /// Describes an element obtained outside a tree visit (hit test, focus),
    /// with a ref when its path from the window can be verified. It belongs to
    /// the app that owns its window, even when another process serves it.
    static func describeLiveElement(_ element: AXUIElement) -> ResolvedElement? {
        guard let snapshot = axSnapshot(element), let role = snapshot.role else { return nil }
        let (window, path) = ancestry(of: element)
        guard let pid = window.flatMap(elementPID) ?? elementPID(element) else { return nil }
        let scope = window.map { elementScope(for: AXWindowSelection(element: $0, pid: pid, expected: nil)).scope }
            ?? appOnlyScope(pid: pid)
        let info = makeElementInfo(
            element, snapshot: snapshot, role: role, actions: axActions(element),
            valueSettable: isValueSettable(element), scope: scope, path: path
        )
        return ResolvedElement(element: element, info: info, scope: scope, path: path)
    }

    /// The element under a desktop point, read before any event is posted.
    static func hitTest(at point: CGPoint) -> ResolvedElement? {
        elementAtPoint(point).flatMap(describeLiveElement)
    }

    /// The raw Accessibility hit test at a desktop point; nil without
    /// Accessibility or when the hit test fails.
    static func elementAtPoint(_ point: CGPoint) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        prepareAXMessaging()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return nil
        }
        return element
    }

    /// "AXButton 'Save'" from one snapshot read, without the ancestry walk of
    /// `describeLiveElement`; nil when the element cannot be read.
    static func briefDescription(of element: AXUIElement) -> String? {
        guard let snapshot = axSnapshot(element), let role = snapshot.role else { return nil }
        return DesktopElementPolicy.describe(DesktopElementPolicy.makeInfo(
            role: role, subrole: snapshot.subrole, title: snapshot.title, description: snapshot.description,
            placeholder: snapshot.placeholder, identifier: snapshot.identifier
        ))
    }

    static func applicationName(of pid: pid_t) -> String {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.localizedName ?? app?.bundleIdentifier ?? "pid \(pid)"
    }

    /// The app a window selection refers to, named in errors raised before the
    /// window itself is resolved: the owner of window_id, else the app picked
    /// by pid, bundle_id, or app_name, else the frontmost app (the same order
    /// as `selectedAXWindow`).
    static func selectedApplicationLabel(_ input: DesktopRunInput) -> String {
        let pid = input.window_id != nil
            ? windowRecords(onScreenOnly: false, matching: input).first?.pid
            : matchingRunningApp(input, defaultToFrontmost: true)?.processIdentifier
        return pid.map(applicationName(of:)) ?? "The application"
    }

    /// Whether `element` is `ancestor` or one of its descendants, climbing
    /// kAXParent at most `maximumDepth` levels; a read error counts as no.
    static func isElement(_ element: AXUIElement, sameAsOrBelow ancestor: AXUIElement, maximumDepth: Int = 64) -> Bool {
        var current = element
        for _ in 0..<maximumDepth {
            if CFEqual(current, ancestor) { return true }
            guard let parent = try? copyAXElement(current, attribute: kAXParentAttribute as CFString, operation: "read parent") else {
                return false
            }
            current = parent
        }
        return CFEqual(current, ancestor)
    }

    static func focusedUIElement(of pid: pid_t) -> AXUIElement? {
        try? copyAXElement(AXUIElementCreateApplication(pid), attribute: kAXFocusedUIElementAttribute as CFString, operation: "read focused element")
    }

    static func describeFocusedElement(of pid: pid_t) -> ResolvedElement? {
        guard AXIsProcessTrusted() else { return nil }
        prepareAXMessaging()
        return focusedUIElement(of: pid).flatMap(describeLiveElement)
    }

    static func systemFocusedApplicationPID() -> pid_t? {
        guard let application = try? copyAXElement(
            AXUIElementCreateSystemWide(), attribute: kAXFocusedApplicationAttribute as CFString, operation: "read focused application"
        ) else {
            return nil
        }
        return elementPID(application)
    }

    /// The app that receives keyboard input, from the system-wide focused
    /// application of Accessibility. Unlike `currentFrontmost()`, which reports
    /// the app in front and falls back to NSWorkspace, there is deliberately no
    /// fallback here: NSWorkspace's frontmost app can be stale in this one-shot
    /// worker, so an Accessibility error leaves the focus unknown (nil), which
    /// callers treat as the focus not obtained, or as a reason to stop the input.
    static func keyboardFocusPID() -> pid_t? {
        systemFocusedApplicationPID()
    }

    static func describeSystemFocusedElement() -> ResolvedElement? {
        guard AXIsProcessTrusted() else { return nil }
        prepareAXMessaging()
        guard let element = try? copyAXElement(
            AXUIElementCreateSystemWide(), attribute: kAXFocusedUIElementAttribute as CFString, operation: "read focused element"
        ) else {
            return nil
        }
        return describeLiveElement(element)
    }

    /// True only when the app with the keyboard focus is the target's app and
    /// its focused element is the target or one of its descendants. Any
    /// Accessibility error or timeout on the way counts as not focused.
    static func hasKeyboardFocus(_ target: ResolvedElement) -> Bool {
        guard keyboardFocusPID() == target.pid, let focused = focusedUIElement(of: target.pid) else { return false }
        return isElement(focused, sameAsOrBelow: target.element)
    }

    static func stackedWindows() -> [DesktopElementPolicy.StackedWindow] {
        guard let dictionaries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return dictionaries.compactMap { dictionary in
            guard let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }
            return DesktopElementPolicy.StackedWindow(
                pid: pid,
                appName: dictionary[kCGWindowOwnerName as String] as? String,
                bounds: bounds,
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            )
        }
    }
}
