//
//  FeatureProcessOutputRenderer.swift
//  ZenCODE
//

import Foundation

/// Stateless renderer for process results. Kept separate from
/// `FeatureProcessResult` so callers holding differently-shaped process types
/// (e.g. already-decoded stdout/stderr strings) can reuse the exact same format.
public enum FeatureProcessOutputRenderer {
    public static func render(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool
    ) -> String {
        var sections = ["exit_code: \(exitCode)"]
        if timedOut {
            sections.append("timed_out: true")
        }
        if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stdout:\n\(stdout)")
        }
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stderr:\n\(stderr)")
        }
        if sections.count == 1 {
            sections.append("<no output>")
        }
        return sections.joined(separator: "\n")
    }
}
