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
        var pid: pid_t { scope.pid }
        var phrase: String { DesktopElementPolicy.locationPhrase(info) }
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
    /// (a terminal scrollback, a document) are read only up to the reported bound.
    static func axDisplayValue(_ element: AXUIElement, role: String, subrole: String?) -> String? {
        guard !DesktopElementPolicy.isSecure(role: role, subrole: subrole) else { return nil }
        if role == kAXTextAreaRole,
           let length = (copyAXRaw(element, attribute: kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue,
           length > 4 * DesktopElementPolicy.maximumValueCharacters {
            var range = CFRange(location: 0, length: DesktopElementPolicy.maximumValueCharacters + 1)
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
        path: [Int]?
    ) -> DesktopElementInfo {
        var info = DesktopElementPolicy.makeInfo(
            role: role,
            subrole: snapshot.subrole,
            roleDescription: snapshot.roleDescription,
            title: snapshot.title,
            description: snapshot.description,
            value: axDisplayValue(element, role: role, subrole: snapshot.subrole),
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
            hostsZen: scope.hostsZen
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
        input.element_ref?.nilIfBlank != nil || input.query?.nilIfBlank != nil
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
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { throw DesktopControlError.appNotFound }
        let pid = frontmost.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        prepareAXMessaging(application)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = try? copyAXElement(application, attribute: attribute as CFString, operation: "read window") {
                return AXWindowSelection(element: window, pid: pid, expected: nil)
            }
        }
        if let first = (copyAXRaw(application, attribute: kAXWindowsAttribute as CFString) as? [AXUIElement])?.first {
            return AXWindowSelection(element: first, pid: pid, expected: nil)
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
    static func visitElements(
        in scope: ElementScope,
        maxDepth: Int,
        interactiveOnly: Bool,
        roleFilter: String?,
        query: String?,
        limit: Int
    ) -> ElementVisit {
        var visit = ElementVisit()
        guard let window = scope.window else { return visit }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(elementTimeBudget))
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
            guard let role = snapshot.role, let frame = snapshot.frame, DesktopElementPolicy.isPositive(frame) else { continue }
            if let roleFilter, !DesktopElementPolicy.roleMatches(roleFilter, role: role, subrole: snapshot.subrole) { continue }
            let actions = axActions(node.element)
            let settable = isValueSettable(node.element)
            if interactiveOnly,
               !DesktopElementPolicy.isInteractive(role: role, subrole: snapshot.subrole, actions: actions, valueSettable: settable) {
                continue
            }
            let info = makeElementInfo(
                node.element, snapshot: snapshot, role: role, actions: actions,
                valueSettable: settable, scope: scope, path: node.path
            )
            if let query, !DesktopElementPolicy.matchesQuery(query, element: info) { continue }
            visit.matches.append(ResolvedElement(element: node.element, info: info, scope: scope, path: node.path))
            if visit.matches.count >= limit {
                visit.stoppedByLimit = !stack.isEmpty
                break
            }
        }
        return visit
    }

    // MARK: Resolution

    static func resolveReference(_ reference: DesktopElementReference) throws -> ResolvedElement {
        guard let app = NSRunningApplication(processIdentifier: reference.pid), !app.isTerminated else {
            throw DesktopControlError.staleElementReference
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
            } catch {
                throw DesktopControlError.staleElementReference
            }
            guard selection.pid == reference.pid else { throw DesktopControlError.staleElementReference }
            window = selection.element
        case let .windowIndex(index, titlePrefix):
            guard let windows = try read(application, kAXWindowsAttribute) as? [AXUIElement] else {
                throw DesktopControlError.staleElementReference
            }
            let titles = try windows.map { try read($0, kAXTitleAttribute) as? String }
            guard let resolved = DesktopElementReference.resolveWindowIndex(titles: titles, index: index, titlePrefix: titlePrefix) else {
                throw DesktopControlError.staleElementReference
            }
            window = windows[resolved]
        }

        var current = window
        for index in reference.path {
            guard let children = try read(current, kAXChildrenAttribute) as? [AXUIElement],
                  children.indices.contains(index) else {
                throw DesktopControlError.staleElementReference
            }
            current = children[index]
        }
        // The element may be served by another process than its window's app
        // (web content of Safari or WKWebView, the Open and Save panels): the
        // window's pid is what the reference recorded, and the path from the
        // window and the fingerprint still pin the element down.
        guard elementPID(window) == reference.pid else { throw DesktopControlError.staleElementReference }
        let snapshot: AXSnapshot
        switch readAXSnapshot(current) {
        case let .snapshot(read): snapshot = read
        case .gone: throw DesktopControlError.staleElementReference
        case .unresponsive: throw DesktopControlError.applicationNotResponding(appName)
        }
        guard snapshot.role == reference.role else { throw DesktopControlError.staleElementReference }
        let scope = elementScope(for: AXWindowSelection(element: window, pid: reference.pid, expected: nil)).scope
        let info = makeElementInfo(
            current, snapshot: snapshot, role: reference.role, actions: axActions(current),
            valueSettable: isValueSettable(current), scope: scope, path: reference.path
        )
        // The same path may now lead to another element (siblings inserted or
        // removed, or the element changed): only the recorded one is accepted.
        guard DesktopElementReference.fingerprint(of: info) == reference.fingerprint else {
            throw DesktopControlError.staleElementReference
        }
        return ResolvedElement(element: current, info: info, scope: scope, path: reference.path)
    }

    /// Resolves the target of an element action from element_ref, or from
    /// query (with an optional role) in the selected window.
    static func resolveElementTarget(_ input: DesktopRunInput, action: String) throws -> ResolvedElement {
        try requireAccessibility()
        prepareAXMessaging()
        let rawReference = input.element_ref?.nilIfBlank
        let query = try DesktopElementPolicy.validatedQuery(input.query)
        if rawReference != nil, query != nil {
            throw DesktopControlError.invalidArgument("element_ref/query", "pass either element_ref or query, not both.")
        }

        if let rawReference {
            let reference = try DesktopElementReference(parsing: rawReference)
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
            return try resolveReference(reference)
        }

        guard let query else { throw DesktopControlError.missingArgument("element_ref or query", action) }
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
            roleFilter: roleFilter, query: query, limit: maximumResolutionMatches
        )
        let candidates = visit.matches.map(\.info)
        switch DesktopElementPolicy.choose(candidates, query: query, visitIsComplete: visit.isComplete) {
        case let .unique(index):
            return visit.matches[index]
        case let .ambiguous(indices):
            throw DesktopControlError.operationFailed(
                DesktopElementPolicy.ambiguityMessage(query: query, candidates: indices.map { candidates[$0] }, scope: scope.phrase)
            )
        case let .incomplete(indices):
            throw DesktopControlError.operationFailed(
                DesktopElementPolicy.incompleteVisitMessage(
                    query: query, candidates: indices.map { candidates[$0] }, scope: scope.phrase,
                    truncation: visit.truncationNote(limit: maximumResolutionMatches, appName: scope.appLabel)
                )
            )
        case .noMatch:
            let message = DesktopElementPolicy.noMatchMessage(
                query: query, role: input.role?.nilIfBlank, scope: scope.phrase, interactiveOnly: interactiveOnly
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

    /// The app that has the system focus, for output that only informs the
    /// model (screenshot and zoom `frontmost_app`): from Accessibility when it
    /// is granted, so a stale NSWorkspace in this one-shot worker cannot name
    /// the wrong app; with an Accessibility error, or without Accessibility,
    /// NSWorkspace's frontmost app. Input never uses this fallback
    /// (`keyboardFocusPID`).
    static func focusedApplicationForReport() -> NSRunningApplication? {
        if AXIsProcessTrusted() {
            prepareAXMessaging()
            if let pid = systemFocusedApplicationPID(), let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// The app that receives keyboard input, from the system-wide focused
    /// application of Accessibility. There is deliberately no fallback to
    /// NSWorkspace's frontmost app, which can be stale in this one-shot worker:
    /// an Accessibility error leaves the focus unknown (nil), which callers
    /// treat as the focus not obtained, or as a reason to stop the input.
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
