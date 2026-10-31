//
//  ChatAttachmentCommandError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Why an `/attach` command line could not run.
///
/// The controller reports it as ``notice``, whose text is `ZenCODE: `
/// followed by ``errorDescription``.
enum ChatAttachmentCommandError: LocalizedError, Equatable {
    /// `/attach delete` got something that is not the number of a staged
    /// attachment.
    case invalidDetachArgument(String)
    /// A quote of the `/attach` arguments is not closed.
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case let .invalidDetachArgument(argument):
            return "Invalid attachment selection: \(argument)."
        case .unterminatedQuote:
            return "Unterminated quoted attachment path."
        }
    }

    /// The notice the controller presents for the error.
    var notice: ChatSessionNotice {
        switch self {
        case let .invalidDetachArgument(argument):
            return .invalidAttachmentSelection(argument: argument)
        case .unterminatedQuote:
            return .unterminatedAttachmentQuote
        }
    }
}
