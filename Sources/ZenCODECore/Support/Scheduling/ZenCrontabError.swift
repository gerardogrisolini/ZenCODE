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
    /// ZenCRON, the host that new scheduled prompts run, is not installed at
    /// its fixed location. `/cron add` refuses before touching the crontab.
    case zenCRONNotInstalled(path: String)
    /// ZenCRON exists but does not report its version, so it cannot start.
    /// `reason` completes "does not start (…)".
    case zenCRONDoesNotStart(path: String, reason: String)
    /// No executable `zen` exists in the `PATH` of the ZenCODE block, which
    /// ZenCRON passes on to the `zen` it starts, so a scheduled prompt could
    /// not run.
    case zenNotOnPath(path: String)
    /// The prompt cannot be stored on a single crontab line.
    case invalidPrompt(reason: String)
    /// The prompt file (`/cron add -f`) cannot be stored on a single crontab
    /// line. A file that is missing, unreadable or empty is reported by
    /// `ZenCODEPromptFileError` instead.
    case invalidPromptFile(reason: String)
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
        case let .zenCRONNotInstalled(path):
            return "ZenCRON is not installed at \(path). "
                + "Build it from /setup › Scheduled prompts (ZenCRON), then retry."
        case let .zenCRONDoesNotStart(path, reason):
            return "ZenCRON at \(path) does not start (\(reason)). "
                + "Rebuild it from /setup › Scheduled prompts (ZenCRON), then retry."
        case let .zenNotOnPath(path):
            return "ZenCRON runs `zen` with PATH=\(path), but no executable zen was found there. "
                + "Install ZenCODE in /usr/local/bin (Scripts/install.sh) before scheduling prompts."
        case let .invalidPrompt(reason):
            return "The prompt cannot be scheduled: \(reason). Rewrite it as a single non-empty line and retry."
        case let .invalidPromptFile(reason):
            return "The prompt file cannot be scheduled: \(reason). "
                + "Use an absolute path to a readable, non-empty UTF-8 text file and retry."
        case let .invalidMailTo(value):
            return "Invalid MAILTO value '\(value)'. Use a plain e-mail address, or /cron mailto none to disable cron mail."
        }
    }
}
