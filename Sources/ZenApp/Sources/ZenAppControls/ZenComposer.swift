//
//  ZenComposer.swift
//  ZenApp
//
//  The floating Liquid Glass prompt composer of the app: the terminal UI's
//  input panel (multi-line draft, history keys, slash-command and @mention
//  completion, the shared-chat reader keys, the key hint under the field)
//  plus attachments, file drops, Send/Stop and the queued prompts.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// A prompt waiting in the session queue, shown as a chip above the field.
public struct ZenComposerQueuedItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// The latest change the owner made to the draft itself, not typed in the
/// field (in the app, the voice dictation previewed at the end of the
/// draft). After each new one the composer moves its cursor where the
/// owner says (``ZenComposerActions/cursorAfterDraftUpdate``).
public struct ZenComposerDraftUpdate: Equatable, Sendable {
    /// Grows with every change; 0 before the first.
    public let revision: Int
    /// The identity of the text the owner shows at the end of the draft
    /// now (the dictation's preview); `nil` without one.
    public let regionID: UInt64?

    /// No change yet.
    public static let none = ZenComposerDraftUpdate(revision: 0, regionID: nil)

    public init(revision: Int, regionID: UInt64?) {
        self.revision = revision
        self.regionID = regionID
    }
}

/// A key of the shared-chat reader, as the terminal maps it while its reader
/// is open: ← and → move between messages, Home and End go to the first and
/// the last one, ↑ and ↓ scroll the message shown.
public enum ZenReaderKey: Sendable, Equatable {
    /// ←: the message before the one shown.
    case previousMessage
    /// →: the message after the one shown.
    case nextMessage
    /// Home: the oldest message.
    case firstMessage
    /// End: the newest message.
    case lastMessage
    /// ↑: scroll the message shown up.
    case scrollUp
    /// ↓: scroll the message shown down.
    case scrollDown
}

/// What the composer asks its owner to do. Every closure runs on the main
/// actor and defaults to a no-op.
public struct ZenComposerActions {
    /// Sends the current draft (the `draft` binding already holds the text to
    /// send; the owner clears it). Never called for a blank draft.
    public var submit: @MainActor () -> Void
    /// Stops the running generation.
    public var stop: @MainActor () -> Void
    /// Opens the attachment picker.
    public var attach: @MainActor () -> Void
    /// File URLs dropped onto the composer.
    public var dropFiles: @MainActor ([URL]) -> Void
    /// Recalls the previous history entry into the draft; `false` when there
    /// is none, so the key keeps its ordinary meaning.
    public var historyPrevious: @MainActor () -> Bool
    /// Recalls the next history entry (or the draft typed before the
    /// recall); `false` when there is none.
    public var historyNext: @MainActor () -> Bool
    /// Removes a queued prompt.
    public var removeQueued: @MainActor (UUID) -> Void
    /// The cursor started completing the leading `@mention` of the draft
    /// (the operator starts typing one, or comes back to edit it): the
    /// operator may be addressing a live participant, so the owner refreshes
    /// the mention roster it passes as ``ZenComposer``'s `mentions`.
    public var refreshMentions: @MainActor () -> Void
    /// An unmodified reader key (``ZenComposerLogic/readerKey(for:modifiers:)``)
    /// pressed in the field: `true` when the owner's shared-chat reader
    /// consumed it, so the key neither moves the cursor nor recalls the
    /// history nor moves the suggestion highlight; `false` (the default)
    /// leaves the key its ordinary meaning.
    public var readerKey: @MainActor (ZenReaderKey) -> Bool
    /// Where the cursor goes, in characters, once the owner changed the
    /// draft itself (``ZenComposer``'s `draftUpdate` went from the first
    /// update to the second, maybe skipping some in one render): from the
    /// cursor before the change and the number of characters of the draft
    /// after it, both in characters. The default keeps the cursor, clamped
    /// to the draft.
    public var cursorAfterDraftUpdate: @MainActor (
        _ cursor: Int,
        _ from: ZenComposerDraftUpdate,
        _ to: ZenComposerDraftUpdate,
        _ draftCount: Int
    ) -> Int

    public init(
        submit: @escaping @MainActor () -> Void = {},
        stop: @escaping @MainActor () -> Void = {},
        attach: @escaping @MainActor () -> Void = {},
        dropFiles: @escaping @MainActor ([URL]) -> Void = { _ in },
        historyPrevious: @escaping @MainActor () -> Bool = { false },
        historyNext: @escaping @MainActor () -> Bool = { false },
        removeQueued: @escaping @MainActor (UUID) -> Void = { _ in },
        refreshMentions: @escaping @MainActor () -> Void = {},
        readerKey: @escaping @MainActor (ZenReaderKey) -> Bool = { _ in false },
        cursorAfterDraftUpdate: @escaping @MainActor (
            Int, ZenComposerDraftUpdate, ZenComposerDraftUpdate, Int
        ) -> Int = { cursor, _, _, draftCount in min(cursor, draftCount) }
    ) {
        self.submit = submit
        self.stop = stop
        self.attach = attach
        self.dropFiles = dropFiles
        self.historyPrevious = historyPrevious
        self.historyNext = historyNext
        self.removeQueued = removeQueued
        self.refreshMentions = refreshMentions
        self.readerKey = readerKey
        self.cursorAfterDraftUpdate = cursorAfterDraftUpdate
    }
}

/// The prompt composer: a floating Liquid Glass container with a multi-line
/// field, an attach button and the Send/Stop buttons, the queued prompts
/// above the field and the slash-command and @mention suggestions above the
/// container.
///
/// Keys mirror the terminal UI's input panel:
/// - Return submits; Shift+Return and Option+Return insert a newline. While
///   an input method is composing (marked text), a plain Return, ↑, ↓, Tab
///   and Esc belong to the input method, suggestions or not.
/// - Slash commands and the first argument of the shared commands complete
///   at the cursor (``ZenCommandSuggestions``). With the suggestion list on
///   screen, ↑/↓ move the highlight (wrapping), Tab completes the
///   highlighted suggestion, Return completes it and sends the draft unless
///   the suggestion requires an argument, Esc hides the list until the next
///   edit.
/// - The leading `@mention` of a single-line draft (`@coordinator`, `@all`,
///   `@<agent-handle>`) completes from the `mentions` the owner passes
///   (``ZenMentionSuggestions``) with the same keys, except that Return, like
///   Tab and a click, only completes the mention (`@handle` and a space):
///   a mention needs a message, so it is never sent by a suggestion.
///   `ZenComposerActions.refreshMentions` asks the owner for a fresh roster
///   when the cursor starts completing that mention, not on every keystroke.
/// - Otherwise ↑ on the first line and ↓ on the last line recall the history;
///   while a recalled entry is unchanged the arrows keep walking the history.
/// - The unmodified ←, →, ↑, ↓, Home and End go first to the owner's
///   shared-chat reader (`ZenComposerActions.readerKey`), ahead of the
///   suggestions and the history, as in the terminal; a key the reader does
///   not consume keeps its ordinary meaning, and so does any key with Shift,
///   Option, Command or Control. An input method composing keeps priority.
///
/// When the owner changes the draft itself (`draftUpdate`, the app's voice
/// dictation), the cursor goes where the owner says
/// (``ZenComposerActions/cursorAfterDraftUpdate``); a selection the move
/// leaves in place stays whole.
///
/// Under the field, inside the container, a line names the keys that do
/// something now, as the terminal's input panel does
/// (``ZenComposerLogic/keyHint(isBusy:isSpeaking:hasSuggestions:)``).
///
/// Prompts submitted while busy are queued by the owner, so Send stays
/// available next to Stop when the draft is not empty.
///
/// The composer's glass (suggestion list, field container, queued chips)
/// shares a `GlassEffectContainer` the composer creates, unless the caller
/// already wraps it in one and passes `usesGlassContainer: false`.
public struct ZenComposer: View {
    @Environment(\.zenPalette) private var palette

    @Binding private var draft: String
    private let isBusy: Bool
    private let isSpeaking: Bool
    private let isEnabled: Bool
    private let commands: [ChatCommandDescriptor]
    private let mentions: [SharedChatMentionParser.Suggestion]
    private let queued: [ZenComposerQueuedItem]
    private let draftUpdate: ZenComposerDraftUpdate?
    private let externalFocus: FocusState<Bool>.Binding?
    private let monospaced: Bool
    private let usesGlassContainer: Bool
    private let actions: ZenComposerActions

    @FocusState private var internalFocus: Bool
    @State private var selection: TextSelection?
    @State private var navigator = ZenSuggestionNavigator()
    /// The draft a history recall left, while it is unchanged.
    @State private var recalledDraft: String?
    @State private var isDropTargeted = false
    /// The width of the attach button, so the key hint starts under the
    /// field's text.
    @State private var attachButtonWidth: CGFloat = 0

    /// The spacing between the attach button, the field and the trailing
    /// buttons.
    private static let rowSpacing: CGFloat = 8

    /// The placeholder of the empty field.
    public static let placeholder = "Message ZenCODE — / for commands"

    /// - Parameters:
    ///   - draft: The text being composed, owned by the caller.
    ///   - isBusy: A prompt is generating: Stop shows.
    ///   - isSpeaking: Voice mode reads aloud and Esc stops it: the key hint
    ///     names it while nothing generates.
    ///   - isEnabled: `false` disables the field, attach and Send (Stop stays
    ///     available while busy).
    ///   - commands: The slash commands the operator can run, in display order.
    ///   - mentions: The live `@mention` catalogue (`@coordinator`, `@all`, the
    ///     active agents), in display order; refreshed by the owner on
    ///     ``ZenComposerActions/refreshMentions``.
    ///   - queued: The prompts waiting in the queue.
    ///   - draftUpdate: The latest change the owner made to the draft itself;
    ///     `nil` when it makes none.
    ///   - focus: The caller's focus binding of the field; `nil` uses an
    ///     internal one that focuses the field when it appears.
    ///   - monospaced: Draws the draft in the monospaced font.
    ///   - usesGlassContainer: Wraps the composer's glass in its own
    ///     `GlassEffectContainer`; pass `false` when the caller already
    ///     provides one, so the containers do not nest.
    ///   - actions: What the composer asks its owner to do.
    public init(
        draft: Binding<String>,
        isBusy: Bool,
        isSpeaking: Bool = false,
        isEnabled: Bool = true,
        commands: [ChatCommandDescriptor] = [],
        mentions: [SharedChatMentionParser.Suggestion] = [],
        queued: [ZenComposerQueuedItem] = [],
        draftUpdate: ZenComposerDraftUpdate? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        monospaced: Bool = false,
        usesGlassContainer: Bool = true,
        actions: ZenComposerActions = ZenComposerActions()
    ) {
        self._draft = draft
        self.isBusy = isBusy
        self.isSpeaking = isSpeaking
        self.isEnabled = isEnabled
        self.commands = commands
        self.mentions = mentions
        self.queued = queued
        self.draftUpdate = draftUpdate
        self.externalFocus = focus
        self.monospaced = monospaced
        self.usesGlassContainer = usesGlassContainer
        self.actions = actions
    }

    public var body: some View {
        glassGroup
            .onChange(of: draft) { _, newValue in
                navigator.draftChanged(to: newValue)
                if recalledDraft != newValue {
                    recalledDraft = nil
                }
            }
            .onChange(of: cursor) { _, _ in
                navigator.cursorMoved()
            }
            .onChange(of: draftPosition) { old, new in
                if ZenMentionSuggestions.refreshesMentions(
                    from: old.draft,
                    oldCursor: old.cursor,
                    to: new.draft,
                    newCursor: new.cursor
                ) {
                    actions.refreshMentions()
                }
            }
            .onChange(of: followedDraft) { old, new in
                followDraftUpdate(from: old, to: new)
            }
            .onAppear {
                if externalFocus == nil {
                    internalFocus = true
                }
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var glassGroup: some View {
        if usesGlassContainer {
            GlassEffectContainer(spacing: 8) {
                stack
            }
        } else {
            stack
        }
    }

    private var stack: some View {
        let matches = visibleSuggestions
        return VStack(alignment: .leading, spacing: 8) {
            if !matches.isEmpty {
                ZenCommandSuggestionList(
                    matches: matches,
                    highlightedIndex: navigator.boundedIndex(count: matches.count),
                    monospaced: monospaced,
                    onSelect: { index in
                        accept(matches[index], submitting: false)
                        focusBinding.wrappedValue = true
                    }
                )
            }
            container(hasSuggestions: !matches.isEmpty)
        }
    }

    private func container(hasSuggestions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !queued.isEmpty {
                queuedChips
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: Self.rowSpacing) {
                    attachButton
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.width
                        } action: { width in
                            attachButtonWidth = width
                        }
                    field
                    trailingButtons
                }
                keyHint(ZenComposerLogic.keyHint(
                    isBusy: isBusy,
                    isSpeaking: isSpeaking,
                    hasSuggestions: hasSuggestions
                ))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(
            .regular.tint(palette.accent.opacity(isDropTargeted ? 0.20 : 0.06)),
            in: .rect(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isDropTargeted ? palette.accent : palette.promptBorder.opacity(0.6),
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = ZenComposerLogic.droppedFiles(urls)
            guard isEnabled, !files.isEmpty else { return false }
            actions.dropFiles(files)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && isEnabled
        }
    }

    private var field: some View {
        TextField(
            "Message",
            text: $draft,
            selection: $selection,
            prompt: Text(Self.placeholder).foregroundStyle(palette.textMuted),
            axis: .vertical
        )
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(monospaced ? ZenFonts.mono : .body)
        .foregroundStyle(palette.textPrimary)
        .lineLimit(1...10)
        .padding(.vertical, 6)
        .focused(focusBinding)
        .disabled(!isEnabled)
        .onKeyPress(.return, phases: .down) { press in
            handleReturn(modifiers: press.modifiers)
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
            handleVerticalKey(delta: -1, modifiers: press.modifiers)
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
            handleVerticalKey(delta: 1, modifiers: press.modifiers)
        }
        .onKeyPress(
            keys: [.leftArrow, .rightArrow, .home, .end],
            phases: [.down, .repeat]
        ) { press in
            handleReaderKey(press.key, modifiers: press.modifiers)
        }
        .onKeyPress(.tab, phases: .down) { _ in
            handleTab()
        }
        .onKeyPress(.escape, phases: .down) { _ in
            handleEscape()
        }
        .onSubmit {
            // Reached only when the key press above did not consume Return.
            _ = handleReturn(modifiers: [])
        }
    }

    private var attachButton: some View {
        Button(action: actions.attach) {
            Image(systemName: "paperclip")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .foregroundStyle(palette.textSecondary)
        .disabled(!isEnabled)
        .help("Attach an image or a movie")
        .accessibilityLabel("Attach")
    }

    /// The key hint, under the field's text, on one line: its compact form
    /// when the full one does not fit, as in the terminal.
    private func keyHint(_ hint: ZenComposerLogic.KeyHint) -> some View {
        keyHintText(hint)
            .font(.caption)
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, attachButtonWidth + Self.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func keyHintText(_ hint: ZenComposerLogic.KeyHint) -> some View {
        if let compact = hint.compact {
            ViewThatFits(in: .horizontal) {
                Text(hint.full)
                Text(compact)
            }
        } else {
            Text(hint.full)
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        let visibility = ZenComposerLogic.buttons(isBusy: isBusy, draft: draft)
        HStack(spacing: 6) {
            if visibility.showsStop {
                Button(action: actions.stop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(palette.statusFailure)
                .help("Stop the generation")
                .accessibilityLabel("Stop")
            }
            if visibility.showsSend {
                Button(action: submitIfPossible) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(palette.accent)
                .disabled(!isEnabled || !ZenComposerLogic.canSend(draft: draft))
                .help(isBusy ? "Queue the prompt" : "Send")
                .accessibilityLabel(isBusy ? "Queue" : "Send")
            }
        }
    }

    private var queuedChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(queued) { item in
                    queuedChip(item)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func queuedChip(_ item: ZenComposerQueuedItem) -> some View {
        HStack(spacing: 6) {
            Text("queued")
                .foregroundStyle(palette.statusQueued)
            Text(ZenComposerLogic.chipText(item.text))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
            Button {
                actions.removeQueued(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textMuted)
            .help("Remove from the queue")
            .accessibilityLabel("Remove queued prompt")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(palette.statusQueued.opacity(0.15)), in: .capsule)
    }

    // MARK: - State

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }

    /// The suggestions on screen: none while disabled, while a recalled
    /// history entry is unchanged, or after Esc dismissed them for this draft.
    private var visibleSuggestions: [ZenSuggestionRow] {
        guard isEnabled,
              recalledDraft != draft,
              !navigator.isDismissed(for: draft) else {
            return []
        }
        return ZenSuggestionRow.rows(
            for: draft,
            cursor: cursor,
            commands: commands,
            mentions: mentions
        )
    }

    /// The cursor of the field in characters; `nil` (the end of the draft)
    /// without an insertion point.
    private var cursor: Int? {
        ZenComposerLogic.cursorOffset(in: draft, selection: selectedRange)
    }

    /// The draft and the cursor, observed together: the roster is refreshed
    /// when the cursor starts completing the leading `@mention`
    /// (``ZenMentionSuggestions/refreshesMentions(from:oldCursor:to:newCursor:)``),
    /// so typing the message after the mention refreshes nothing.
    private var draftPosition: DraftPosition {
        DraftPosition(draft: draft, cursor: cursor)
    }

    /// A draft and the cursor in it (`nil`: the end of the draft).
    private struct DraftPosition: Equatable {
        let draft: String
        let cursor: Int?
    }

    /// The draft, the selection in it, and the owner's latest change to it,
    /// observed together: when the change is new, the selection of the draft
    /// before it is the one the cursor moves from
    /// (``followDraftUpdate(from:to:)``).
    private var followedDraft: FollowedDraft {
        FollowedDraft(
            draft: draft,
            selection: ZenComposerLogic.selectionOffsets(in: draft, selection: selectedRange),
            update: draftUpdate
        )
    }

    /// A draft, the selection in it in characters (`nil`: the end of the
    /// draft), and the owner's latest change.
    private struct FollowedDraft: Equatable {
        let draft: String
        let selection: Range<Int>?
        let update: ZenComposerDraftUpdate?
    }

    /// The owner changed the draft itself: the cursor moves where it says,
    /// from where it was in the draft before the change.
    private func followDraftUpdate(from old: FollowedDraft, to new: FollowedDraft) {
        guard let update = new.update else { return }
        let previous = old.update ?? .none
        guard update.revision != previous.revision else { return }
        let draftCount = new.draft.count
        let followed = ZenComposerLogic.followedSelection(
            old.selection,
            previousDraftCount: old.draft.count,
            draftCount: draftCount
        ) { cursor in
            actions.cursorAfterDraftUpdate(cursor, previous, update, draftCount)
        }
        selection = ZenComposerLogic.textSelection(followed, in: draft)
    }

    // MARK: - Keys

    private func handleReturn(modifiers: EventModifiers) -> KeyPress.Result {
        let highlighted = navigator.highlighted(in: visibleSuggestions)
        switch ZenComposerLogic.returnAction(
            modifiers: modifiers,
            hasSuggestion: highlighted != nil,
            hasMarkedText: ZenComposerLogic.focusedInputHasMarkedText()
        ) {
        case .insertNewline:
            insertNewline()
        case .acceptSuggestion:
            if let highlighted {
                accept(highlighted, submitting: true)
            }
        case .passThrough:
            // The input method commits its composition; `.onSubmit` stays
            // the fallback of a real submission.
            return .ignored
        case .submit:
            submitIfPossible()
        }
        return .handled
    }

    private func handleVerticalKey(delta: Int, modifiers: EventModifiers) -> KeyPress.Result {
        // The input method's candidate window owns ↑ and ↓ while it composes.
        guard !ZenComposerLogic.focusedInputHasMarkedText() else { return .ignored }
        // An open reader scrolls its message, over the suggestions too.
        if readerConsumes(delta < 0 ? .upArrow : .downArrow, modifiers: modifiers) {
            return .handled
        }
        let matches = visibleSuggestions
        if !matches.isEmpty {
            navigator.move(by: delta, count: matches.count)
            return .handled
        }

        let isRecalling = recalledDraft != nil && recalledDraft == draft
        guard isRecalling || ZenComposerLogic.cursorIsOnBoundaryLine(
            draft,
            selection: selectedRange,
            movingUp: delta < 0
        ) else {
            return .ignored
        }

        let recalled = delta < 0 ? actions.historyPrevious() : actions.historyNext()
        guard recalled else {
            return isRecalling ? .handled : .ignored
        }
        // The binding reads the owner's draft, already replaced by the recall.
        let current = draft
        recalledDraft = current
        selection = TextSelection(insertionPoint: current.endIndex)
        return .handled
    }

    /// ←, →, Home and End: the reader's when it consumes them, otherwise the
    /// field's (cursor moves, selection).
    private func handleReaderKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        guard !ZenComposerLogic.focusedInputHasMarkedText() else { return .ignored }
        return readerConsumes(key, modifiers: modifiers) ? .handled : .ignored
    }

    /// Offers a reader key to the owner: `true` when it consumed it.
    private func readerConsumes(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard let readerKey = ZenComposerLogic.readerKey(for: key, modifiers: modifiers) else {
            return false
        }
        return actions.readerKey(readerKey)
    }

    private func handleTab() -> KeyPress.Result {
        guard !ZenComposerLogic.focusedInputHasMarkedText(),
              let suggestion = navigator.highlighted(in: visibleSuggestions) else {
            return .ignored
        }
        accept(suggestion, submitting: false)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        // Esc while an input method composes cancels the composition.
        guard !ZenComposerLogic.focusedInputHasMarkedText() else { return .ignored }
        guard !visibleSuggestions.isEmpty else {
            // Let the window's Esc handle it: it denies a waiting tool
            // consent, otherwise it stops the turn.
            return .ignored
        }
        navigator.dismiss(draft: draft)
        return .handled
    }

    // MARK: - Editing

    private var selectedRange: Range<String.Index>? {
        guard case let .selection(range)? = selection?.indices else {
            return nil
        }
        return range
    }

    /// Accepts a suggestion for the token under the cursor. `submitting` is
    /// Return: a mention never submits, whatever the key.
    private func accept(_ suggestion: ZenSuggestionRow, submitting: Bool) {
        guard let acceptance = suggestion.accept(
            in: draft,
            cursor: cursor,
            submitting: submitting
        ) else {
            return
        }
        draft = acceptance.draft
        let text = acceptance.draft
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: acceptance.cursor))
        if acceptance.submits {
            submitIfPossible()
        }
    }

    private func insertNewline() {
        guard isEnabled else { return }
        let edit = ZenComposerLogic.insertingNewline(into: draft, replacing: selectedRange)
        draft = edit.text
        selection = TextSelection(insertionPoint: edit.cursor)
    }

    private func submitIfPossible() {
        guard isEnabled, ZenComposerLogic.canSend(draft: draft) else { return }
        recalledDraft = nil
        actions.submit()
    }
}

/// The pure rules behind ``ZenComposer``.
public enum ZenComposerLogic {
    /// Which of Send and Stop are on screen: Send when idle, Stop while busy,
    /// both while busy with a draft to queue.
    struct ButtonVisibility: Equatable {
        let showsSend: Bool
        let showsStop: Bool
    }

    static func buttons(isBusy: Bool, draft: String) -> ButtonVisibility {
        guard isBusy else {
            return ButtonVisibility(showsSend: true, showsStop: false)
        }
        return ButtonVisibility(showsSend: canSend(draft: draft), showsStop: true)
    }

    /// The key hint under the field, in the terminal's words: its input-panel
    /// help (`TerminalInteractiveLineReader.panelHelpTextLocked`) for the
    /// keys of the composer and its window, listing, like the terminal, only
    /// the keys that do something now. Ctrl+G is Session > Full Access and
    /// Ctrl+Y the chat reader, both menu key equivalents that also work from
    /// the field.
    struct KeyHint: Equatable {
        /// The whole hint.
        let full: String
        /// The hint when the whole one does not fit (`Esc stop` or
        /// `Esc stop reading` ahead of the other keys, as the terminal's
        /// compact help); `nil` when the whole one is the only form.
        let compact: String?
    }

    /// The hint for the composer's state:
    /// - with suggestions on screen, their keys (Esc hides them, busy,
    ///   reading aloud, or not);
    /// - while busy, Return queues and Esc stops the turn, the reading aloud
    ///   too, as in the terminal, where the turn's help wins;
    /// - while voice mode reads aloud (`isSpeaking`), Return sends and Esc
    ///   stops the reading;
    /// - otherwise Return sends, and Esc, which has nothing to stop and does
    ///   not clear the draft, is not listed.
    static func keyHint(isBusy: Bool, isSpeaking: Bool, hasSuggestions: Bool) -> KeyHint {
        if hasSuggestions {
            return KeyHint(full: "↑/↓ select · Tab complete · Enter choose · Esc dismiss", compact: nil)
        }
        if isBusy {
            return KeyHint(
                full: "Enter queue · Ctrl+G access · Ctrl+Y chat · Esc stop",
                compact: "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat"
            )
        }
        if isSpeaking {
            return KeyHint(
                full: "Enter send · Ctrl+G access · Ctrl+Y chat · Esc stop reading",
                compact: "Enter send · Esc stop reading · Ctrl+G access · Ctrl+Y chat"
            )
        }
        return KeyHint(full: "Enter send · Ctrl+G access · Ctrl+Y chat", compact: nil)
    }

    /// A draft with something other than whitespace.
    static func canSend(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The file URLs of a drop.
    static func droppedFiles(_ urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL)
    }

    /// A queued prompt on one line.
    static func chipText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether the cursor is on the first line (moving up) or on the last line
    /// (moving down) of `text`, so the arrow recalls the history instead of
    /// moving between lines. Without a selection the cursor is at the end.
    static func cursorIsOnBoundaryLine(
        _ text: String,
        selection: Range<String.Index>?,
        movingUp: Bool
    ) -> Bool {
        let cursor: String.Index
        if let selection {
            cursor = min(movingUp ? selection.lowerBound : selection.upperBound, text.endIndex)
        } else {
            cursor = text.endIndex
        }
        return movingUp
            ? !text[..<cursor].contains("\n")
            : !text[cursor...].contains("\n")
    }

    /// `text` with the selection (or the end, without one) replaced by a
    /// newline, and the cursor after it.
    static func insertingNewline(
        into text: String,
        replacing selection: Range<String.Index>?
    ) -> (text: String, cursor: String.Index) {
        var result = text
        let lower = min(selection?.lowerBound ?? text.endIndex, text.endIndex)
        let upper = min(max(selection?.upperBound ?? text.endIndex, lower), text.endIndex)
        let offset = text.distance(from: text.startIndex, to: lower)
        result.replaceSubrange(lower..<upper, with: "\n")
        let cursor = result.index(result.startIndex, offsetBy: offset + 1)
        return (result, cursor)
    }

    /// The cursor of `selection` in `text`, in characters: the insertion
    /// point inside the text. `nil`, which completion reads as the end of
    /// the draft, without a selection, for a range, or for an index outside
    /// `text` (a selection left over from an older draft).
    static func cursorOffset(in text: String, selection: Range<String.Index>?) -> Int? {
        guard let selection,
              selection.isEmpty,
              selection.lowerBound >= text.startIndex,
              selection.lowerBound <= text.endIndex else {
            return nil
        }
        return text.distance(from: text.startIndex, to: selection.lowerBound)
    }

    /// The selection of `selection` in `text`, in characters; `nil` without
    /// one, or for an index outside `text` (a selection left over from an
    /// older draft).
    static func selectionOffsets(in text: String, selection: Range<String.Index>?) -> Range<Int>? {
        guard let selection,
              selection.lowerBound >= text.startIndex,
              selection.upperBound <= text.endIndex else {
            return nil
        }
        let lower = text.distance(from: text.startIndex, to: selection.lowerBound)
        return lower..<(lower + text.distance(from: selection.lowerBound, to: selection.upperBound))
    }

    /// The selection, in characters, once the owner changed the draft
    /// itself: the cursor (the end of `selection`; without one, the end of
    /// the draft before the change, `previousDraftCount` characters) goes
    /// where `place` puts it, clamped to the draft, now `draftCount`
    /// characters. A selection whose end `place` leaves where it was stays
    /// whole.
    static func followedSelection(
        _ selection: Range<Int>?,
        previousDraftCount: Int,
        draftCount: Int,
        place: (Int) -> Int
    ) -> Range<Int> {
        let range = selection ?? previousDraftCount..<previousDraftCount
        let cursor = range.upperBound
        let target = min(max(place(cursor), 0), draftCount)
        guard target != cursor else { return range }
        return target..<target
    }

    /// The index `characterOffset` characters into `text`, clamped to it. A
    /// character is a `Character`: an emoji or an accented letter is one,
    /// however many UTF-16 units the field counts for it.
    static func index(in text: String, characterOffset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(characterOffset, 0), text.count))
    }

    /// The field's selection of `offsets`, characters of `text`: string
    /// indices, which the field maps to its UTF-16 range.
    static func textSelection(_ offsets: Range<Int>, in text: String) -> TextSelection {
        let lower = index(in: text, characterOffset: offsets.lowerBound)
        let upper = index(in: text, characterOffset: offsets.upperBound)
        return lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// What Return does in the field.
    enum ReturnAction: Equatable {
        /// Shift+Return, Option+Return.
        case insertNewline
        /// Accept the highlighted suggestion (sending the draft when it is
        /// complete).
        case acceptSuggestion
        /// Leave the key to the field: an input method is composing.
        case passThrough
        /// Send the draft.
        case submit
    }

    /// The meaning of Return: Shift or Option inserts a newline; while an
    /// input method composes (marked text) a plain Return belongs to the
    /// input method, which commits the composition, even over a highlighted
    /// suggestion; with a highlighted suggestion it accepts it; otherwise it
    /// sends the draft.
    static func returnAction(
        modifiers: EventModifiers,
        hasSuggestion: Bool,
        hasMarkedText: Bool
    ) -> ReturnAction {
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            return .insertNewline
        }
        if hasMarkedText {
            return .passThrough
        }
        if hasSuggestion {
            return .acceptSuggestion
        }
        return .submit
    }

    /// The reader key of a key press, as the terminal maps it while its reader
    /// is open: ← previous, → next, Home first, End last message, ↑/↓ scroll.
    /// Only unmodified keys: with Shift, Option, Command or Control a key
    /// keeps its text-editing meaning (`nil`). Caps Lock and the numeric-pad
    /// and function flags the arrow keys carry do not count.
    public static func readerKey(for key: KeyEquivalent, modifiers: EventModifiers) -> ZenReaderKey? {
        guard modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else {
            return nil
        }
        switch key {
        case .leftArrow: return .previousMessage
        case .rightArrow: return .nextMessage
        case .home: return .firstMessage
        case .end: return .lastMessage
        case .upArrow: return .scrollUp
        case .downArrow: return .scrollDown
        default: return nil
        }
    }

    /// Whether the focused text input of the key window holds marked text,
    /// i.e. an input method (IME, dead keys, press-and-hold accents) is
    /// composing in the field editor. While it does, Return, ↑, ↓, Tab and
    /// Esc belong to the input method, in the composer and in the window.
    @MainActor
    public static func focusedInputHasMarkedText() -> Bool {
        guard let responder = NSApplication.shared.keyWindow?.firstResponder,
              let input = responder as? any NSTextInputClient else {
            return false
        }
        return input.hasMarkedText()
    }
}

#Preview("Composer – idle") {
    @Previewable @State var draft = ""
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands
    )
    .padding()
    .frame(width: 640)
}

#Preview("Composer – suggestions") {
    @Previewable @State var draft = "/s"
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands,
        monospaced: true
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .bottom)
}

#Preview("Composer – mentions") {
    @Previewable @State var draft = "@"
    ZenComposer(
        draft: $draft,
        isBusy: false,
        commands: ZenControlsPreviewData.commands,
        mentions: ZenControlsPreviewData.mentions,
        monospaced: true
    )
    .padding()
    .frame(width: 640, height: 320, alignment: .bottom)
}

#Preview("Composer – busy with queue") {
    @Previewable @State var draft = "And then run the tests"
    ZenComposer(
        draft: $draft,
        isBusy: true,
        commands: ZenControlsPreviewData.commands,
        queued: [
            ZenComposerQueuedItem(text: "Refactor the status bar formatting"),
            ZenComposerQueuedItem(text: "Write the\nchangelog entry")
        ]
    )
    .padding()
    .frame(width: 640)
}

/// Sample values of the previews.
enum ZenControlsPreviewData {
    static let commands: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(command: "/help", summary: "show the commands", help: "/help"),
        ChatCommandDescriptor(command: "/sessions", summary: "manage saved sessions", help: "/sessions"),
        ChatCommandDescriptor(command: "/skills", summary: "select skills", help: "/skills"),
        ChatCommandDescriptor(
            command: "/save",
            summary: "save the session as",
            help: "/save <name>",
            requiresArgument: true
        ),
        ChatCommandDescriptor(command: "/models", summary: "choose the model", help: "/models")
    ]

    static let mentions: [SharedChatMentionParser.Suggestion] = [
        SharedChatMentionParser.Suggestion(handle: "coordinator", target: .coordinator),
        SharedChatMentionParser.Suggestion(handle: "all", target: .all),
        SharedChatMentionParser.Suggestion(handle: "reviewer", target: .agent(name: "Reviewer")),
        SharedChatMentionParser.Suggestion(handle: "builder-2", target: .agent(name: "Builder"))
    ]

    static let items: [ChatChoiceItem] = [
        ChatChoiceItem(id: "a", title: "Qwen3-Coder-30B", detail: "local · 4bit", group: "MLX", isCurrent: true),
        ChatChoiceItem(id: "b", title: "Devstral-Small", detail: "local · 8bit", group: "MLX"),
        ChatChoiceItem(id: "c", title: "gpt-5", detail: "subscription", group: "OpenAI"),
        ChatChoiceItem(id: "d", title: "gpt-5-mini", group: "OpenAI")
    ]
}
