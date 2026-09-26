//
//  LocalExecCommandParser.swift
//  ZenCODE
//
//  Parses `local.exec` command strings to extract authorization-relevant
//  information: pipeline/sequence segmentation and per-segment executable
//  identity. Pure (no side effects).
//

import Foundation

/// Pure helper that segments `local.exec` command strings into individual
/// commands and extracts the executable identity that should be authorized,
/// stripping shell noise (redirections, environment assignments, built-ins,
/// control keywords, grouping delimiters) so prompts surface the real
/// executable instead of tokens like `true` or `FOO=bar`.
enum LocalExecCommandParser {
    /// Result of identifying the executable for an authorization segment.
    enum Identity: Equatable, Sendable {
        /// A concrete executable name worth prompting for (e.g. `swift`).
        case executable(String)
        /// A harmless shell built-in or control keyword that should not be
        /// prompted for (e.g. `true`, `cd`).
        case skip
        /// The parser could not confidently resolve the executable; fall back
        /// to the first raw token (legacy behaviour) for safety.
        case unresolved(String)
    }

    /// A structured authorization candidate extracted from a command string.
    /// Carries the canonical executable identity (for dedup/cache/persistence)
    /// and a cleaned significant invocation (for display/authorization).
    struct AuthorizationCandidate: Equatable, Sendable {
        let identity: String
        let invocation: String
    }

    /// Outcome of authorization analysis.  In particular, an incomplete
    /// analysis is intentionally distinct from a command which is known to be
    /// safe: callers must obtain consent for the former rather than treating an
    /// empty candidate list as permission to execute.
    enum AuthorizationAnalysis: Equatable, Sendable {
        case safe
        case candidates([AuthorizationCandidate])
        case incomplete(reason: String)
    }

    }
