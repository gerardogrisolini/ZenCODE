//
//  BrowserInteraction.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Controlled semantic Browser interaction. The public contract accepts only
//  opaque snapshot refs and constrained actions; raw CDP and JavaScript remain
//  internal implementation details.
//

import FeatureKit
import ToolCore
import Foundation
import Synchronization

// MARK: - Errors and output

enum BrowserInteractionError: LocalizedError, Equatable {
    case staleSnapshot
    case targetNoLongerAvailable(String)
    case targetIsNotInteractive(String)
    case unsupportedFillTarget(String)
    case sensitiveInputRequiresUser
    case fileInputNotSupported
    case inputIsDisabled
    case inputValueTooLarge
    case unsupportedSelectTarget(String)
    case optionNotFound(String)
    case unsupportedCheckTarget(String)
    case targetIsDisabled
    case unableToSetCheckedState(String)
    case unsupportedKey(String)
    case fillNotApplied(String)
    case targetIsCovered(String, String)
    case targetOutsideViewport(String)
    case unsupportedScrollDirection(String)
    case invalidScrollAmount

    var errorDescription: String? {
        switch self {
        case .staleSnapshot:
            "The Browser snapshot is stale or does not authorize this element. Take a fresh browser.snapshot before acting."
        case let .targetNoLongerAvailable(ref):
            "Browser element '\(ref)' is no longer available. Take a fresh browser.snapshot."
        case let .targetIsNotInteractive(ref):
            "Browser element '\(ref)' is not an interactive semantic control."
        case let .unsupportedFillTarget(ref):
            "Browser element '\(ref)' cannot be filled. Use a text input, textarea, or rich-text editor (contenteditable) from a fresh snapshot; if the composer is behind a button such as \"Start a post\", click it first."
        case .sensitiveInputRequiresUser:
            "Browser will not fill password-like fields. Ask the user to type the value directly into the visible Chrome window."
        case .fileInputNotSupported:
            "Browser will not populate file upload inputs. Ask the user to choose the file in the visible Chrome window."
        case .inputIsDisabled:
            "Browser cannot fill a disabled or read-only control."
        case .inputValueTooLarge:
            "Browser fill values are limited to 16,000 UTF-8 bytes."
        case let .unsupportedSelectTarget(ref):
            "Browser element '\(ref)' is not a selectable HTML select control."
        case let .optionNotFound(ref):
            "Browser element '\(ref)' does not contain an option with that value. Take a fresh browser.snapshot and inspect the control before selecting."
        case let .unsupportedCheckTarget(ref):
            "Browser element '\(ref)' is not a checkbox or radio control that Browser can set."
        case .targetIsDisabled:
            "Browser cannot change a disabled control."
        case let .unableToSetCheckedState(ref):
            "Browser element '\(ref)' did not reach the requested checked state. Take a fresh browser.snapshot before retrying."
        case let .unsupportedKey(key):
            "Unsupported Browser key '\(key)'. Use a navigation or editing key such as Enter, Tab, Escape, ArrowDown, Backspace, or Delete, optionally combined with Control, Meta, Alt, or Shift (for example Control+A, Meta+Enter, Shift+Tab). Letters and digits require a Control, Meta, or Alt modifier; use fill to enter text."
        case let .fillNotApplied(ref):
            "Browser typed into element '\(ref)', but the editor did not keep the requested text. Take a fresh browser.snapshot: the editor may have been replaced, or it may need a click to activate first."
        case let .targetIsCovered(ref, obstruction):
            "Browser element '\(ref)' is covered by another element (page content, untrusted: \(obstruction)), so a click would land on it instead. Close the overlay, dialog, or banner first (for example press Escape or click its close button from a fresh snapshot), then retry."
        case let .targetOutsideViewport(ref):
            "Browser element '\(ref)' could not be brought into the visible viewport. Use the scroll action on its container, then take a fresh browser.snapshot."
        case let .unsupportedScrollDirection(direction):
            "Unsupported Browser scroll direction '\(direction)'. Use up, down, left, or right."
        case .invalidScrollAmount:
            "Browser scroll amount must be between 1 and 100,000 CSS pixels."
        }
    }
}

enum BrowserActionKind: String, Codable, Sendable {
    case click
    case fill
    case press
    case hover
    case doubleClick = "double_click"
    case scrollIntoView = "scroll_into_view"
    case selectOption = "select_option"
    case check
    case uncheck
    case scroll

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("action")
        }
        guard let action = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError(
                "Unsupported Browser action '\(rawValue)'. Use click, fill, press, hover, double_click, scroll, scroll_into_view, select_option, check, or uncheck."
            )
        }
        return action
    }
}

enum BrowserDialogAction: String, Codable, Sendable {
    case accept
    case dismiss

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("action")
        }
        guard let action = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError("Unsupported Browser dialog action '\(rawValue)'. Use accept or dismiss.")
        }
        return action
    }
}

struct BrowserDialogInfo: Codable, Hashable, Sendable {
    let type: String
    let message: String
    let defaultPrompt: String?
    let url: String?
}

struct BrowserActionOutput: Codable, Sendable {
    let page: BrowserPage
    let action: BrowserActionKind
    let targetRef: String?
    let dialog: BrowserDialogInfo?
    let fill: BrowserFillReport?
    let scroll: BrowserScrollReport?
    let note: String

    init(
        page: BrowserPage,
        action: BrowserActionKind,
        targetRef: String?,
        dialog: BrowserDialogInfo?,
        fill: BrowserFillReport? = nil,
        scroll: BrowserScrollReport? = nil
    ) {
        self.page = page
        self.action = action
        self.targetRef = targetRef
        self.dialog = dialog
        self.fill = fill
        self.scroll = scroll
        self.note = dialog == nil
            ? "The action was dispatched through Browser's constrained semantic interaction API."
            : "A JavaScript dialog is open. Call browser.dialog explicitly to accept or dismiss it."
    }
}

struct BrowserDialogOutput: Codable, Sendable {
    let page: BrowserPage
    let action: BrowserDialogAction
    let note: String

    init(page: BrowserPage, action: BrowserDialogAction) {
        self.page = page
        self.action = action
        self.note = "The JavaScript dialog was handled explicitly. Browser does not supply prompt text on the model's behalf."
    }
}

private enum BrowserInteractionText {
    static let maximumBytes = 4_000

    static func clipped(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.lengthOfBytes(using: .utf8) > maximumBytes else { return value }
        let result = value.prefixFitting(utf8Bytes: maximumBytes)
        return result + "…"
    }
}

private final class BrowserDialogObserver: Sendable {
    private struct State: Sendable {
        var latestDialog: BrowserDialogInfo?
    }
    private let state = Mutex(State())

    func consume(_ event: CDPEvent) {
        guard event.method == "Page.javascriptDialogOpening" else { return }
        let params = event.params
        let dialog = BrowserDialogInfo(
            type: params["type"] as? String ?? "unknown",
            message: BrowserInteractionText.clipped(params["message"] as? String) ?? "",
            defaultPrompt: BrowserInteractionText.clipped(params["defaultPrompt"] as? String),
            url: BrowserInteractionText.clipped(params["url"] as? String)
        )
        state.withLock { state in
            state.latestDialog = dialog
            return
        }
    }

    var dialog: BrowserDialogInfo? {
        state.withLock { state in
            state.latestDialog
        }
    }
}

// MARK: - Key input

enum BrowserKeyPlatform: Sendable {
    case macOS
    case other

    static var current: BrowserKeyPlatform {
        #if os(macOS)
        .macOS
        #else
        .other
        #endif
    }
}

struct BrowserKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    // CDP Input.dispatchKeyEvent modifier bits.
    static let alt = BrowserKeyModifiers(rawValue: 1)
    static let control = BrowserKeyModifiers(rawValue: 2)
    static let meta = BrowserKeyModifiers(rawValue: 4)
    static let shift = BrowserKeyModifiers(rawValue: 8)

    static func named(_ rawValue: String) -> BrowserKeyModifiers? {
        switch rawValue.lowercased() {
        case "ctrl", "control": .control
        case "meta", "cmd", "command": .meta
        case "alt", "option", "opt": .alt
        case "shift": .shift
        default: nil
        }
    }
}

struct BrowserKeyStroke: Equatable, Sendable {
    let key: String
    let code: String
    let virtualKeyCode: Int
    let modifiers: BrowserKeyModifiers
    /// Text the key produces; nil for keys that only trigger behavior.
    let text: String?
    /// Chrome editor commands that must accompany the key event.
    let commands: [String]

    init(
        key: String,
        code: String,
        virtualKeyCode: Int,
        modifiers: BrowserKeyModifiers = [],
        text: String? = nil,
        commands: [String] = []
    ) {
        self.key = key
        self.code = code
        self.virtualKeyCode = virtualKeyCode
        self.modifiers = modifiers
        self.text = text
        self.commands = commands
    }

    private static let namedKeys: [String: BrowserKeyStroke] = [
        "enter": .init(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\r"),
        "tab": .init(key: "Tab", code: "Tab", virtualKeyCode: 9),
        "escape": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
        "esc": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
        "space": .init(key: " ", code: "Space", virtualKeyCode: 32, text: " "),
        "backspace": .init(key: "Backspace", code: "Backspace", virtualKeyCode: 8),
        "delete": .init(key: "Delete", code: "Delete", virtualKeyCode: 46),
        "arrowup": .init(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38),
        "arrowdown": .init(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40),
        "arrowleft": .init(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37),
        "arrowright": .init(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39),
        "home": .init(key: "Home", code: "Home", virtualKeyCode: 36),
        "end": .init(key: "End", code: "End", virtualKeyCode: 35),
        "pageup": .init(key: "PageUp", code: "PageUp", virtualKeyCode: 33),
        "pagedown": .init(key: "PageDown", code: "PageDown", virtualKeyCode: 34),
    ]

    /// macOS editing shortcuts. Chrome performs them only when the editor
    /// command travels with the synthetic key event.
    private static let macOSCommandShortcuts: [String: String] = [
        "a": "selectAll",
        "c": "copy",
        "x": "cut",
        "v": "paste",
        "z": "undo",
    ]

    /// Resolves `Key` or a `Modifier+...+Key` combination such as
    /// `Control+A`, `Meta+Enter`, or `Shift+Tab`. A bare letter or digit is
    /// rejected: text entry belongs to `fill`, and only a Control, Meta, or
    /// Alt modifier turns a character into a shortcut.
    static func resolve(_ rawValue: String?, platform: BrowserKeyPlatform = .current) throws -> BrowserKeyStroke {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("key")
        }
        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let baseName = parts.last, parts.allSatisfy({ !$0.isEmpty }) else {
            throw BrowserInteractionError.unsupportedKey(rawValue)
        }
        var modifiers: BrowserKeyModifiers = []
        for name in parts.dropLast() {
            guard let modifier = BrowserKeyModifiers.named(name), !modifiers.contains(modifier) else {
                throw BrowserInteractionError.unsupportedKey(rawValue)
            }
            modifiers.insert(modifier)
        }
        let producesText = modifiers.isSubset(of: [.shift])

        let normalized = baseName
            .lowercased()
            .filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
        if let named = namedKeys[normalized] {
            return BrowserKeyStroke(
                key: named.key,
                code: named.code,
                virtualKeyCode: named.virtualKeyCode,
                modifiers: modifiers,
                text: producesText ? named.text : nil
            )
        }

        guard baseName.count == 1,
              let character = baseName.lowercased().first,
              character.isASCII,
              character.isLetter || character.isNumber,
              !modifiers.isDisjoint(with: [.control, .meta, .alt])
        else {
            throw BrowserInteractionError.unsupportedKey(rawValue)
        }
        let upper = String(character).uppercased()
        let virtualKeyCode = Int(upper.unicodeScalars.first?.value ?? 0)
        var commands: [String] = []
        if platform == .macOS, modifiers.contains(.meta), modifiers.isSubset(of: [.meta, .shift]) {
            if character == "z", modifiers.contains(.shift) {
                commands = ["redo"]
            } else if !modifiers.contains(.shift), let command = macOSCommandShortcuts[String(character)] {
                commands = [command]
            }
        }
        return BrowserKeyStroke(
            key: modifiers.contains(.shift) ? upper : String(character),
            code: character.isLetter ? "Key\(upper)" : "Digit\(character)",
            virtualKeyCode: virtualKeyCode,
            modifiers: modifiers,
            commands: commands
        )
    }

    /// The platform's select-all shortcut, used before replacing editor text.
    static func selectAll(platform: BrowserKeyPlatform = .current) -> BrowserKeyStroke {
        // `try!` is safe: the literal is a supported combination.
        try! resolve(platform == .macOS ? "Meta+A" : "Control+A", platform: platform)
    }

    /// A soft line break. Shift+Enter inserts a newline in rich-text editors
    /// without triggering the "send on Enter" behavior of chat composers.
    static let softLineBreak = BrowserKeyStroke(
        key: "Enter",
        code: "Enter",
        virtualKeyCode: 13,
        modifiers: .shift,
        text: "\r"
    )

    static let backspace = BrowserKeyStroke(key: "Backspace", code: "Backspace", virtualKeyCode: 8)
}

// MARK: - Hit testing

enum BrowserHitTestResult: Equatable, Sendable {
    case clear
    case outsideViewport
    case covered(String)

    static let maximumObstructionBytes = 160

    static func parse(_ raw: String) -> BrowserHitTestResult {
        if raw == "offscreen" { return .outsideViewport }
        guard raw.hasPrefix("covered:") else {
            // `ok`, `unknown` (for example an iframe) and unexpected values
            // keep the previous behavior: click at the computed point.
            return .clear
        }
        let detail = String(raw.dropFirst("covered:".count))
        let clipped = detail.lengthOfBytes(using: .utf8) > maximumObstructionBytes
            ? detail.prefixFitting(utf8Bytes: maximumObstructionBytes) + "…"
            : detail
        return .covered(clipped.isEmpty ? "unknown element" : clipped)
    }
}

// MARK: - DOM and Input helpers

struct BrowserDOMElementInfo {
    let tagName: String
    let attributes: [String: String]

    var isPasswordLike: Bool {
        let sensitiveValues = [
            attributes["type"],
            attributes["autocomplete"],
            attributes["name"],
            attributes["id"],
            attributes["aria-label"],
            attributes["placeholder"],
        ]
        .compactMap { $0?.lowercased() }
        return sensitiveValues.contains { value in
            value.contains("password") || value.contains("passcode") || value.contains("secret")
        }
    }

    var isFileInput: Bool {
        tagName == "input" && attributes["type"]?.lowercased() == "file"
    }
}

// MARK: - Public tools

struct BrowserActTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let snapshotId: String?
        let snapshot_id: String?
        let action: String?
        let ref: String?
        let value: String?
        let key: String?
        let direction: String?
        let amount: Double?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvedSnapshotID: String? {
            snapshotId?.nilIfBlank ?? snapshot_id?.nilIfBlank
        }

        var resolvedRef: String? {
            ref?.nilIfBlank
        }
    }

    static let name = "browser.act"
    static let description = "Performs one constrained semantic action on a ref returned by the current browser.snapshot: click, fill, press, hover, double_click, scroll, scroll_into_view, select_option, check, or uncheck. fill replaces the text of inputs, textareas, and rich-text editors (contenteditable, including social-media composers) with trusted typing and verifies the result. scroll moves the page or the scroll container of ref. Clicks fail with an explicit error when an overlay covers the target. Password-like and file inputs are never filled. Actions can have external side effects."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("snapshotId", description: "snapshotId returned by the most recent browser.snapshot for this page."),
            .string("snapshot_id", description: "Snake-case alias for snapshotId."),
            .string("action", enumValues: ["click", "fill", "press", "hover", "double_click", "scroll", "scroll_into_view", "select_option", "check", "uncheck"], description: "Constrained semantic action."),
            .string("ref", description: "Opaque element ref from that snapshot. Required for every action except press and scroll. For scroll, ref selects the element whose scroll container moves; omit it to scroll the page."),
            .string("value", description: "Value for fill (replaces the current text; newlines become line breaks) or exact option value for select_option. Never use this for passwords or secrets."),
            .string("key", description: "Supported key for press, such as Enter, Tab, Escape, ArrowDown, Backspace, or Delete, optionally with modifiers: Control+A, Meta+Enter, Shift+Tab, Control+Shift+ArrowLeft."),
            .string("direction", enumValues: ["up", "down", "left", "right"], description: "Direction for scroll (defaults to down)."),
            .number("amount", description: "Distance for scroll in CSS pixels (1 through 100000; defaults to about one viewport)."),
        ],
        required: ["pageId", "snapshotId", "action"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserActionOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        guard let snapshotID = input.resolvedSnapshotID else { throw BrowserToolsFeatureError.missingArgument("snapshotId") }
        let action = try BrowserActionKind.resolve(input.action)
        let ref = input.resolvedRef

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let authorization = BrowserSnapshotAuthorization(pageID: tab.id, snapshotID: snapshotID, ref: ref)
            try await session.validateSnapshotState(authorization)
            let observer = BrowserDialogObserver()
            let token = session.addEventHandler { event in
                observer.consume(event)
            }
            defer { session.removeEventHandler(token) }

            var fillReport: BrowserFillReport?
            var scrollReport: BrowserScrollReport?
            switch action {
            case .click:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.click(target: target, authorization: authorization)
            case .fill:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                guard let value = input.value else { throw BrowserToolsFeatureError.missingArgument("value") }
                let target = try await session.resolveSnapshotTarget(authorization)
                fillReport = try await session.fill(target: target, value: value, authorization: authorization)
            case .press:
                if ref != nil {
                    let target = try await session.resolveSnapshotTarget(authorization)
                    try await session.focus(target: target, authorization: authorization)
                }
                // Keyboard input can navigate too, so only validate before
                // dispatch and never after the action.
                try await session.validateSnapshotState(authorization)
                try await session.press(BrowserKeyStroke.resolve(input.key))
            case .hover:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.hover(target: target, authorization: authorization)
            case .doubleClick:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.doubleClick(target: target, authorization: authorization)
            case .scrollIntoView:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.scrollIntoView(target: target, authorization: authorization)
            case .scroll:
                let direction = try BrowserScrollDirection.resolve(input.direction)
                let amount = try BrowserScrollDirection.resolveAmount(input.amount)
                let target = ref == nil ? nil : try await session.resolveSnapshotTarget(authorization)
                scrollReport = try await session.scroll(
                    target: target,
                    direction: direction,
                    amount: amount,
                    authorization: authorization
                )
            case .selectOption:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                guard let value = input.value else { throw BrowserToolsFeatureError.missingArgument("value") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.selectOption(target: target, value: value, authorization: authorization)
            case .check:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.setChecked(target: target, checked: true, authorization: authorization)
            case .uncheck:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.setChecked(target: target, checked: false, authorization: authorization)
            }

            try await Task.sleep(for: .milliseconds(150))
            let dialog = observer.dialog
            if dialog == nil {
                try? await session.waitNavigatedReady()
            }
            let page = dialog == nil
                ? (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
                : BrowserPage(tab: tab)
            return BrowserActionOutput(
                page: page,
                action: action,
                targetRef: ref,
                dialog: dialog,
                fill: fillReport,
                scroll: scrollReport
            )
        }
    }
}

struct BrowserDialogTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let action: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.dialog"
    static let description = "Explicitly accepts or dismisses a JavaScript dialog already opened on a persistent Browser page. Browser does not provide prompt text on the model's behalf."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId with the open dialog."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("action", enumValues: ["accept", "dismiss"], description: "How to handle the open dialog."),
        ],
        required: ["pageId", "action"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserDialogOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        let action = try BrowserDialogAction.resolve(input.action)
        return try await BrowserToolsRunner.withPage(
            pageID: pageID,
            context: context,
            preparePage: false,
            validateCurrentDocument: false
        ) { session, tab in
            _ = try await session.send(method: "Page.handleJavaScriptDialog", params: ["accept": action == .accept])
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserDialogOutput(page: page, action: action)
        }
    }
}

// MARK: - Semantic presentation

extension BrowserActTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser action", action: "Perform", kind: .other, targetKeyPaths: ["action", "ref", "pageId", "page_id"])
    }
}

extension BrowserDialogTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser dialog", action: "Handle", kind: .communicate, targetKeyPaths: ["action", "pageId", "page_id"])
    }
}
