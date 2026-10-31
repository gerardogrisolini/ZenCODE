//
//  ChatChannelCapabilities.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Interactions a chat channel can offer to the shared session controller.
///
/// A channel declares what its host can actually do, and the shared runtime
/// adapts instead of guessing from the transport: a host without
/// ``toolConsent`` never receives consent requests (gated tools are refused
/// with a diagnostic), and only a host with ``serialConsentDialogs`` has its
/// consent dialogs queued one at a time.
public struct ChatChannelCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The host can ask the operator to approve a gated tool call.
    public static let toolConsent = ChatChannelCapabilities(rawValue: 1 << 0)
    /// Consent dialogs share one input surface and must be shown one at a time.
    public static let serialConsentDialogs = ChatChannelCapabilities(rawValue: 1 << 1)
    /// The host can present a single-choice menu.
    public static let singleChoice = ChatChannelCapabilities(rawValue: 1 << 2)
    /// The host can present a multiple-choice menu.
    public static let multipleChoice = ChatChannelCapabilities(rawValue: 1 << 3)
    /// The host can read one free-text line from the operator.
    public static let textInput = ChatChannelCapabilities(rawValue: 1 << 4)
    /// The host renders file artifacts live while the turn runs.
    public static let liveFileArtifacts = ChatChannelCapabilities(rawValue: 1 << 5)
    /// The host can present a multiple-choice menu whose cursor rests on one
    /// item, returning the ticked items together with the focused one.
    public static let focusedMultipleChoice = ChatChannelCapabilities(rawValue: 1 << 6)
}
