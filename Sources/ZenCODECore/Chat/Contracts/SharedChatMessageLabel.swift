//
//  SharedChatMessageLabel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation

/// The route label of a live shared-chat message, for every channel that shows
/// one: `Worker [18:05:09] → Coordinator`. The terminal reader and the macOS
/// app render the same label, so a message reads identically wherever the
/// operator follows the conversation.
///
/// The label is presentation only. It never carries identity or routing:
/// delivery, mentions and the participant map stay keyed on the stable
/// participant identifiers, and a display name is looked up only to be shown.
///
/// The terminal chat keeps its historical name (`TerminalChat`'s
/// `sharedChatIncomingCardRoute(for:participantMap:)`) as a forwarder to this
/// type, so the terminal output stays byte-identical.
public enum SharedChatMessageLabel {
    /// Formats the original send instant as a 24-hour `HH:mm:ss` clock in
    /// `timeZone`, independently of the user's 12/24-hour clock preference. A
    /// value-style formatter avoids shared mutable state when a channel
    /// rebuilds its entries, and the fixed `en_US_POSIX` locale and gregorian
    /// calendar keep the digits and separators stable across user settings.
    ///
    /// - Parameters:
    ///   - sentAt: The instant the message was sent, never the render time.
    ///   - timeZone: The zone the clock is shown in; the local zone by default.
    public static func timestamp(
        _ sentAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        sentAt.formatted(
            Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: timeZone,
                calendar: Calendar(identifier: .gregorian)
            )
        )
    }

    /// Builds the author label of a message from its sender, the original send
    /// time and the resolved recipients: `<sender> [<time>] → <recipient>`.
    ///
    /// The recipient reads `Coordinator` when the recipients contain the
    /// room's coordinator, `All` for more than one recipient, `Operator` for
    /// the operator identifier, the recipient's display name when it is in
    /// `participantMap`, and `Agent` otherwise. Participant identities and
    /// delivery stay unchanged.
    ///
    /// - Parameters:
    ///   - message: The message to label.
    ///   - participantMap: The room's participants keyed by identifier, used to
    ///     name a single direct recipient.
    ///   - timeZone: The zone the send time is shown in; the local zone by
    ///     default.
    public static func route(
        for message: AgentSharedChat.Message,
        participantMap: [String: AgentSharedChat.Participant] = [:],
        timeZone: TimeZone = .current
    ) -> String {
        let senderName = "\(AgentSharedChat.displayName(for: message.sender)) [\(timestamp(message.sentAt, timeZone: timeZone))]"
        let coordinatorID = AgentSharedChat.coordinatorID(for: message.roomID)
        if message.recipientIDs.contains(coordinatorID) {
            return "\(senderName) → Coordinator"
        }
        if message.recipientIDs.count > 1 {
            return "\(senderName) → All"
        }
        if let recipientID = message.recipientIDs.first,
           AgentSharedChat.isOperatorIdentifier(recipientID) {
            return "\(senderName) → Operator"
        }
        if let recipientID = message.recipientIDs.first,
           let recipient = participantMap[recipientID] {
            return "\(senderName) → \(AgentSharedChat.displayName(for: recipient))"
        }
        return "\(senderName) → Agent"
    }
}
