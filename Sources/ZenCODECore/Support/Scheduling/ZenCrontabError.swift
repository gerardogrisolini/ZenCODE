//
//  ZenCrontabError.swift
//  ZenCODE
//

import Foundation

/// Failures shared by the `/cron` scheduling stack: the pure crontab codec,
/// the crontab client, the runner and the TUI command.
///
/// Descriptions are user-facing English and always suggest a remedy.
enum ZenCrontabError: LocalizedError, Equatable {
    /// The `crontab` binary is missing or cannot be launched.
    case crontabUnavailable
    /// `crontab` ran but exited with a non-zero status. `detail` carries the
    /// trimmed stderr text (possibly empty).
    case commandFailed(status: Int32, detail: String)
    /// The ZenCODE-owned block of the crontab cannot be interpreted safely.
    case malformedBlock(reason: String)
    /// A 1-based scheduled-prompt number that does not exist.
    case noSuchEntry(Int)
    /// No executable `zen` exists in the `PATH` cron gives to the ZenCODE
    /// block, so a scheduled prompt could not start.
    case zenNotOnPath(path: String)
    /// The prompt cannot be stored on a single crontab line.
    case invalidPrompt(reason: String)
    /// The `MAILTO` value is not acceptable.
    case invalidMailTo(String)

    var errorDescription: String? {
        switch self {
        case .crontabUnavailable:
            return "crontab is not installed; see zen --doctor"
        case let .commandFailed(status, detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "crontab failed with exit status \(status). Check that your user is allowed to use crontab, then retry."
            }
            return "crontab failed with exit status \(status): \(trimmed)"
        case let .malformedBlock(reason):
            return "The ZenCODE block in your crontab is malformed: \(reason). "
                + "Fix it with `crontab -e` (keep a single '# >>> ZenCODE cron >>>' / '# <<< ZenCODE cron <<<' pair) and retry."
        case let .noSuchEntry(number):
            return "No scheduled prompt #\(number). Use /cron list."
        case let .zenNotOnPath(path):
            return "cron runs `zen` with PATH=\(path), but no executable zen was found there. "
                + "Install ZenCODE in /usr/local/bin (Scripts/install.sh) before scheduling prompts."
        case let .invalidPrompt(reason):
            return "The prompt cannot be scheduled: \(reason). Rewrite it as a single non-empty line and retry."
        case let .invalidMailTo(value):
            return "Invalid MAILTO value '\(value)'. Use a plain e-mail address, or an empty value to disable cron mail."
        }
    }
}
