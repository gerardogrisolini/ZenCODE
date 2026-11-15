//
//  ZenPendingRequests.swift
//  ZenApp
//
//  Presents the session's pending operator requests (tool consents, text
//  line, attachment picker, workspace access) and answers each one exactly
//  once. The choice menus are a popover of their own
//  (`ZenPendingMenuPopover.swift`).
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZenCODECore

extension View {
    /// Presents `request` and reports the operator's answer with `onAnswer`.
    ///
    /// - `.toolConsent`: a ``ZenConsentSheet``.
    /// - `.readLine`: a ``ZenTextLineSheet``.
    /// - `.pickAttachment`: the file importer (images and movies, one file,
    ///   opened at the starting directory), answering `.attachment(url)`.
    /// - `.workspaceAccess`: answered `.workspaceAccess(granted: true)` at
    ///   once, since the app is not sandboxed.
    /// - A kind newer than the app: answered `nil` at once, so the command
    ///   that asked never waits for an answer the app cannot give.
    ///
    /// The menus (`.chooseOne`, `.chooseMany`, `.chooseManyWithFocus`) are
    /// not presented here, and wait:
    /// ``zenPendingMenuPopover(_:arrowEdge:onAnswer:)`` presents them in a
    /// ``ZenChoicePopover``, applied to the view the popover points to.
    ///
    /// The sheet closes when the request disappears or changes id. Each
    /// request is answered at most once: a cancelled or dismissed sheet or
    /// importer answers `nil` (for a tool consent, a refusal); a request
    /// withdrawn by the session is not answered.
    public func zenPendingRequests(
        _ request: ChatPendingRequest?,
        onAnswer: @escaping @MainActor (UUID, ChatPendingRequest.Answer?) -> Void
    ) -> some View {
        modifier(ZenPendingRequestsModifier(request: request, onAnswer: onAnswer))
    }
}

/// The surface that presents a request kind.
enum ZenPendingRequestPresentation: Equatable {
    /// A choice menu popover
    /// (``View/zenPendingMenuPopover(_:arrowEdge:onAnswer:)``).
    case menu(ZenChoiceMenuState)
    /// A text line sheet.
    case textLine(prompt: String)
    /// The file importer.
    case attachmentPicker(startingAt: URL)
    /// Granted without asking.
    case grantWorkspaceAccess
    /// A tool consent sheet.
    case consent(AgentToolAuthorizationRequest)
    /// A kind the app does not know: answered `nil` without asking.
    case unsupported

    init(kind: ChatPendingRequest.Kind) {
        switch kind {
        case .chooseOne, .chooseMany, .chooseManyWithFocus:
            // `ZenChoiceMenuState(kind:)` succeeds for every menu kind.
            self = ZenChoiceMenuState(kind: kind).map(Self.menu) ?? .unsupported
        case let .readLine(prompt):
            self = .textLine(prompt: prompt)
        case let .pickAttachment(directory):
            self = .attachmentPicker(startingAt: directory)
        case .workspaceAccess:
            self = .grantWorkspaceAccess
        case let .toolConsent(request):
            self = .consent(request)
        @unknown default:
            self = .unsupported
        }
    }

    /// The answer the modifier sends on its own as soon as the request
    /// appears, without presenting anything: the workspace access grant, and
    /// `nil` for a kind the app does not know. `nil` for every other kind,
    /// which waits for the operator.
    var automaticAnswer: ZenAutomaticAnswer? {
        switch self {
        case .grantWorkspaceAccess:
            return ZenAutomaticAnswer(answer: .workspaceAccess(granted: true))
        case .unsupported:
            return ZenAutomaticAnswer(answer: nil)
        case .menu, .textLine, .attachmentPicker, .consent:
            return nil
        }
    }

    /// The answer of the attachment importer: the picked file, or `nil` on
    /// failure or without a file.
    static func attachmentAnswer(_ result: Result<[URL], any Error>) -> ChatPendingRequest.Answer? {
        guard case let .success(urls) = result, let url = urls.first else {
            return nil
        }
        return .attachment(url)
    }
}

/// An answer sent without presenting anything; `answer` is `nil` for a
/// refusal.
struct ZenAutomaticAnswer: Equatable {
    let answer: ChatPendingRequest.Answer?
}

/// Bookkeeping that keeps every request answered at most once. Each
/// presenting modifier keeps its own: the window sheets and the importer
/// (``View/zenPendingRequests(_:onAnswer:)``), the menu popover
/// (``View/zenPendingMenuPopover(_:arrowEdge:onAnswer:)``).
struct ZenPendingRequestGate: Equatable {
    private(set) var answeredIDs: Set<UUID> = []
    /// The request whose sheet or popover appeared last.
    private(set) var presentedID: UUID?
    /// The request whose importer was dismissed (its answer comes from the
    /// importer's completion or cancellation).
    private(set) var dismissedImporterID: UUID?

    /// Whether `id` has not been answered yet.
    func isOpen(_ id: UUID) -> Bool {
        !answeredIDs.contains(id)
    }

    /// Marks `id` answered; `false` when it already was, so the caller must
    /// not answer again.
    mutating func claim(_ id: UUID) -> Bool {
        answeredIDs.insert(id).inserted
    }

    /// Notes that the sheet or the popover of the request `id` is on screen.
    mutating func presentationDidAppear(_ id: UUID) {
        presentedID = id
    }

    /// The request a dismissed sheet or popover answers with `nil`: the one
    /// on screen, when it still shows the current request and was not
    /// answered. A sheet or popover closed because its request was withdrawn,
    /// replaced, or hidden answers nothing.
    func dismissalTarget(currentRequestID: UUID?) -> UUID? {
        guard let presentedID,
              presentedID == currentRequestID,
              isOpen(presentedID) else {
            return nil
        }
        return presentedID
    }

    mutating func importerDidDismiss(_ id: UUID) {
        dismissedImporterID = id
    }

    /// Whether the importer is on screen for the request `id`.
    func presentsImporter(for id: UUID) -> Bool {
        isOpen(id) && dismissedImporterID != id
    }
}

/// A sheet presented for a request: a tool consent or a text line.
struct ZenPresentedSheet: Identifiable, Equatable {
    enum Content: Equatable {
        case consent(AgentToolAuthorizationRequest)
        case textLine(prompt: String)
    }

    let id: UUID
    let content: Content

    /// The sheet of the request `id` of `kind` while it waits for its
    /// answer; `nil` once it is answered, and for a kind without a sheet: a
    /// menu (a popover, ``ZenPresentedMenu``), the importer, and the kinds
    /// answered without asking.
    init?(id: UUID, kind: ChatPendingRequest.Kind, gate: ZenPendingRequestGate) {
        guard gate.isOpen(id) else { return nil }
        switch ZenPendingRequestPresentation(kind: kind) {
        case let .consent(consentRequest):
            content = .consent(consentRequest)
        case let .textLine(prompt):
            content = .textLine(prompt: prompt)
        case .menu, .attachmentPicker, .grantWorkspaceAccess, .unsupported:
            return nil
        }
        self.id = id
    }

    /// The sheet of `request`, as ``init(id:kind:gate:)``; `nil` without a
    /// request.
    init?(request: ChatPendingRequest?, gate: ZenPendingRequestGate) {
        guard let request else { return nil }
        self.init(id: request.id, kind: request.kind, gate: gate)
    }
}

struct ZenPendingRequestsModifier: ViewModifier {
    let request: ChatPendingRequest?
    let onAnswer: @MainActor (UUID, ChatPendingRequest.Answer?) -> Void

    @State private var gate = ZenPendingRequestGate()

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding) { sheet in
                sheetView(sheet)
                    .onAppear { gate.presentationDidAppear(sheet.id) }
            }
            .fileImporter(
                isPresented: importerBinding,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: false,
                onCompletion: { result in
                    guard let id = attachmentRequestID else { return }
                    answer(id, ZenPendingRequestPresentation.attachmentAnswer(result))
                },
                onCancellation: {
                    guard let id = attachmentRequestID else { return }
                    answer(id, nil)
                }
            )
            .fileDialogDefaultDirectory(attachmentDirectory)
            .onChange(of: request?.id, initial: true) { _, _ in
                answerAutomaticallyIfNeeded()
            }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(_ sheet: ZenPresentedSheet) -> some View {
        switch sheet.content {
        case let .consent(request):
            ZenConsentSheet(request: request) { decision in
                answer(sheet.id, decision.map(ChatPendingRequest.Answer.consent))
            }
        case let .textLine(prompt):
            ZenTextLineSheet(prompt: prompt) { text in
                answer(sheet.id, text.map { .text($0) })
            }
        }
    }

    private var sheetBinding: Binding<ZenPresentedSheet?> {
        Binding(
            get: { ZenPresentedSheet(request: request, gate: gate) },
            set: { newValue in
                guard newValue == nil,
                      let id = gate.dismissalTarget(currentRequestID: request?.id) else {
                    return
                }
                answer(id, nil)
            }
        )
    }

    // MARK: - Attachment importer

    private var attachmentRequestID: UUID? {
        guard let request, case .pickAttachment = request.kind else { return nil }
        return request.id
    }

    private var attachmentDirectory: URL? {
        guard case let .pickAttachment(directory)? = request?.kind else { return nil }
        return directory
    }

    private var importerBinding: Binding<Bool> {
        Binding(
            get: { attachmentRequestID.map { gate.presentsImporter(for: $0) } ?? false },
            set: { isPresented in
                guard !isPresented, let id = attachmentRequestID else { return }
                gate.importerDidDismiss(id)
            }
        )
    }

    // MARK: - Answers

    /// Grants workspace access and refuses an unknown kind, once per request.
    private func answerAutomaticallyIfNeeded() {
        guard let request,
              let automatic = ZenPendingRequestPresentation(kind: request.kind).automaticAnswer else {
            return
        }
        answer(request.id, automatic.answer)
    }

    private func answer(_ id: UUID, _ answer: ChatPendingRequest.Answer?) {
        guard gate.claim(id) else { return }
        onAnswer(id, answer)
    }
}
