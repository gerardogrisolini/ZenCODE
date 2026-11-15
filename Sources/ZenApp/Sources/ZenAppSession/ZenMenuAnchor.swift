//
//  ZenMenuAnchor.swift
//  ZenApp
//
//  A point of a window, other than the composer, that launched a line.
//

/// A point of the window, other than the composer, from which the operator
/// launched a line (a toolbar button), and over which the menus that line
/// asks for open (``ZenWindowSession/pendingRequestAnchor``). The session
/// does not know the toolbar: the window names the point with `id`.
public struct ZenMenuAnchor: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
