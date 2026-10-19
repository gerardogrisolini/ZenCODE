//
//  TerminalTelegramAPIClient+Errors.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

public enum TerminalTelegramControlError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case invalidToken
    case emptyMessage
    case unexpectedResponse
    case fileTooLarge(limit: Int)
    /// The encoded multipart body would exceed the upload budget.
    case payloadTooLarge(limit: Int)
    /// An outbound artifact was rejected by the anti-exfiltration policy.
    case artifactPathRejected
    /// The inbound attachment store is saturated.
    case attachmentStoreBusy
    /// Transport-level failure with an undecodable body (connection errors,
    /// HTML error pages). Kept for compatibility with existing callers.
    case httpError(Int, String?)
    /// Decoded Bot API error envelope: `ok:false` with `error_code`,
    /// `description` and an optional `retry_after` (via `parameters`).
    case apiFailure(status: Int, errorCode: Int?, description: String?, retryAfter: Int?)
    /// The Bot API `retry_after` this error carries, if any.
    public var retryAfter: Int? {
        guard case let .apiFailure(_, _, _, retryAfter) = self else { return nil }
        return retryAfter
    }
    /// `true` when this is an explicit 429 rate-limit verdict from Telegram.
    public var isExplicitRateLimit: Bool {
        guard case let .apiFailure(status, _, _, _) = self else { return false }
        return status == 429
    }

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Telegram is not configured. Run the /setup command in zen and enable Telegram remote control."
        case .invalidToken:
            return "Telegram bot token is invalid."
        case .emptyMessage:
            return "Cannot send an empty Telegram message."
        case .unexpectedResponse:
            return "Telegram returned an unexpected response."
        case let .fileTooLarge(limit):
            return "Telegram audio exceeds the \(limit)-byte download limit."
        case let .payloadTooLarge(limit):
            return "The upload exceeds the \(limit)-byte multipart budget."
        case .artifactPathRejected:
            return "This file cannot be exported: it is outside the allowed directories, is a secret, or is not an exportable type."
        case .attachmentStoreBusy:
            return "Too many attachments are being received. Try again shortly."
        case let .httpError(statusCode, body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "Telegram returned HTTP \(statusCode): \(Self.boundedDiagnostic(Self.redactingToken(in: detail)))"
            }
            return "Telegram returned HTTP \(statusCode)."
        case let .apiFailure(status, errorCode, description, retryAfter):
            var text = "Telegram API error "
            if let errorCode {
                text += "\(errorCode)"
            } else {
                text += "(HTTP \(status))"
            }
            if let description, !description.isEmpty {
                text += ": \(Self.boundedDiagnostic(Self.redactingToken(in: description)))"
            }
            if let retryAfter {
                text += " (retry after \(retryAfter)s)"
            }
            return text
        }
    }
}

extension TerminalTelegramControlError {
    /// Upper bound for operator-facing diagnostics. An HTML error page from a
    /// proxy can be tens of kilobytes; `lastError` and the terminal only need
    /// the beginning.
    static let maximumDiagnosticLength = 512

    /// Operator-facing text for any error raised on a Telegram path, suitable
    /// for `lastError`, the terminal and the linked chat: any bot token
    /// (`bot<id>:<secret>`, as embedded in Bot API and file URLs) is removed and
    /// the text is bounded.
    static func operatorDescription(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return boundedDiagnostic(redactingToken(in: raw))
    }

    static func redactingToken(in text: String) -> String {
        text.replacingOccurrences(
            of: #"bot\d+:[A-Za-z0-9_\-]+"#,
            with: "bot<redacted>",
            options: .regularExpression
        )
    }

    static func boundedDiagnostic(_ text: String) -> String {
        guard text.count > maximumDiagnosticLength else { return text }
        return String(text.prefix(maximumDiagnosticLength)) + "…"
    }
}

struct TerminalTelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
    /// Mirrors the Bot API error envelope (`ok:false`).
    let errorCode: Int?
    /// Optional error parameters; currently only `retry_after`.
    let parameters: TerminalTelegramResponseParameters?

    private enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
        case errorCode = "error_code"
        case parameters
    }
}

/// `parameters` of a Bot API error envelope.
struct TerminalTelegramResponseParameters: Decodable, Sendable, Equatable {
    let retryAfter: Int?

    private enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}

