//
//  ZenPendingRequests.swift
//  ZenApp
//
//  Presents the session's pending operator requests (tool consents, menus,
//  text line, attachment picker, workspace access) and answers each one
//  exactly once.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZenCODECore

extension View {
    /// Presents `request` and reports the operator's answer with `onAnswer`.
    ///
    /// - `.toolConsent`: a ``ZenConsentSheet``.
    /// - `.chooseOne`, `.chooseMany`, `.chooseManyWithFocus`: a
    ///   ``ZenChoiceSheet``.
    /// - `.readLine`: a ``ZenTextLineSheet``.
    /// - `.pickAttachment`: the file importer (images and movies, one file,
    ///   opened at the starting directory), answering `.attachment(url)`.
    /// - `.workspaceAccess`: answered `.workspaceAccess(granted: true)` at
    ///   once, since the app is not sandboxed.
    /// - A kind newer than the app: answered `nil` at once, so the command
    ///   that asked never waits for an answer the app cannot give.
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
    /// A choice menu sheet.
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

/// Bookkeeping that keeps every request answered at most once.
struct ZenPendingRequestGate: Equatable {
    private(set) var answeredIDs: Set<UUID> = []
    /// The request whose sheet appeared last.
    private(set) var presentedSheetID: UUID?
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

    mutating func sheetDidAppear(_ id: UUID) {
        presentedSheetID = id
    }

    /// The request a dismissed sheet answers with `nil`: the sheet on screen,
    /// when it still shows the current request and was not answered. A sheet
    /// closed because its request was withdrawn or replaced answers nothing.
    func sheetDismissalTarget(currentRequestID: UUID?) -> UUID? {
        guard let presentedSheetID,
              presentedSheetID == currentRequestID,
              isOpen(presentedSheetID) else {
            return nil
        }
        return presentedSheetID
    }

    mutating func importerDidDismiss(_ id: UUID) {
        dismissedImporterID = id
    }

    /// Whether the importer is on screen for the request `id`.
    func presentsImporter(for id: UUID) -> Bool {
        isOpen(id) && dismissedImporterID != id
    }
}

/// A sheet presented for a request.
struct ZenPresentedSheet: Identifiable {
    enum Content {
        case consent(AgentToolAuthorizationRequest)
        case menu(ZenChoiceMenuState)
        case textLine(prompt: String)
    }

    let id: UUID
    let content: Content
}

struct ZenPendingRequestsModifier: ViewModifier {
    let request: ChatPendingRequest?
    let onAnswer: @MainActor (UUID, ChatPendingRequest.Answer?) -> Void

    @State private var gate = ZenPendingRequestGate()

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding) { sheet in
                sheetView(sheet)
                    .onAppear { gate.sheetDidAppear(sheet.id) }
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
        case let .menu(state):
            ZenChoiceSheet(state: state) { value in
                answer(sheet.id, value)
            }
        case let .textLine(prompt):
            ZenTextLineSheet(prompt: prompt) { text in
                answer(sheet.id, text.map { .text($0) })
            }
        }
    }

    private var presentedSheet: ZenPresentedSheet? {
        guard let request, gate.isOpen(request.id) else { return nil }
        switch ZenPendingRequestPresentation(kind: request.kind) {
        case let .consent(consentRequest):
            return ZenPresentedSheet(id: request.id, content: .consent(consentRequest))
        case let .menu(state):
            return ZenPresentedSheet(id: request.id, content: .menu(state))
        case let .textLine(prompt):
            return ZenPresentedSheet(id: request.id, content: .textLine(prompt: prompt))
        case .attachmentPicker, .grantWorkspaceAccess, .unsupported:
            return nil
        }
    }

    private var sheetBinding: Binding<ZenPresentedSheet?> {
        Binding(
            get: { presentedSheet },
            set: { newValue in
                guard newValue == nil,
                      let id = gate.sheetDismissalTarget(currentRequestID: request?.id) else {
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
