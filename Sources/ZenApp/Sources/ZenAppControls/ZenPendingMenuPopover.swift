//
//  ZenPendingMenuPopover.swift
//  ZenApp
//
//  Presents the session's pending choice menus in a popover over the view
//  it points to, and answers each one exactly once. The other requests are
//  sheets of the window (`ZenPendingRequests.swift`).
//

import Foundation
import SwiftUI
import ZenCODECore

extension View {
    /// Presents `request`, when it is a menu (`.chooseOne`, `.chooseMany`,
    /// `.chooseManyWithFocus`), in a ``ZenChoicePopover`` over this view, its
    /// arrow pointing to it from `arrowEdge` (`.top`, the default, opens the
    /// popover above the view; `.bottom` under it), and reports the
    /// operator's answer with `onAnswer`. Every other kind is left to
    /// ``zenPendingRequests(_:onAnswer:)``.
    ///
    /// The popover closes when the request disappears or changes id. Each
    /// menu is answered at most once: a cancelled popover, or one closed by
    /// Esc or a click outside it, answers `nil`; a request withdrawn by the
    /// session, replaced, or hidden (`request` becomes `nil` while it waits)
    /// is not answered, and a hidden one shows again when `request` is back.
    public func zenPendingMenuPopover(
        _ request: ChatPendingRequest?,
        arrowEdge: Edge = .top,
        onAnswer: @escaping @MainActor (UUID, ChatPendingRequest.Answer?) -> Void
    ) -> some View {
        modifier(ZenPendingMenuPopoverModifier(request: request, arrowEdge: arrowEdge, onAnswer: onAnswer))
    }
}

/// A menu presented in a popover for a request.
struct ZenPresentedMenu: Identifiable, Equatable {
    let id: UUID
    let state: ZenChoiceMenuState

    /// The menu of the request `id` of `kind` while it waits for its answer;
    /// `nil` once it is answered, and for every kind that is not a menu (a
    /// sheet, ``ZenPresentedSheet``, the importer, or answered without
    /// asking).
    init?(id: UUID, kind: ChatPendingRequest.Kind, gate: ZenPendingRequestGate) {
        guard gate.isOpen(id),
              case let .menu(state) = ZenPendingRequestPresentation(kind: kind) else {
            return nil
        }
        self.id = id
        self.state = state
    }

    /// The menu of `request`, as ``init(id:kind:gate:)``; `nil` without a
    /// request.
    init?(request: ChatPendingRequest?, gate: ZenPendingRequestGate) {
        guard let request else { return nil }
        self.init(id: request.id, kind: request.kind, gate: gate)
    }
}

struct ZenPendingMenuPopoverModifier: ViewModifier {
    let request: ChatPendingRequest?
    let arrowEdge: Edge
    let onAnswer: @MainActor (UUID, ChatPendingRequest.Answer?) -> Void

    /// Its own: the kinds this modifier answers (the menus) are not the
    /// ones of ``ZenPendingRequestsModifier``.
    @State private var gate = ZenPendingRequestGate()

    func body(content: Content) -> some View {
        content
            .popover(item: menuBinding, arrowEdge: arrowEdge) { menu in
                ZenChoicePopover(state: menu.state) { value in
                    answer(menu.id, value)
                }
                .onAppear { gate.presentationDidAppear(menu.id) }
            }
    }

    private var menuBinding: Binding<ZenPresentedMenu?> {
        Binding(
            get: { ZenPresentedMenu(request: request, gate: gate) },
            set: { newValue in
                guard newValue == nil,
                      let id = gate.dismissalTarget(currentRequestID: request?.id) else {
                    return
                }
                answer(id, nil)
            }
        )
    }

    private func answer(_ id: UUID, _ answer: ChatPendingRequest.Answer?) {
        guard gate.claim(id) else { return }
        onAnswer(id, answer)
    }
}
