//
//  ZenDoctorReportRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Renders a ``ZenDoctorReport`` as plain, secret-free text suitable for stdout.
///
/// The output is deterministic and free of ANSI escapes so it can be redirected
/// to a file, pasted into an issue, or scraped by scripts. Because every field
/// in the report is already redacted, the renderer performs no additional
/// sanitization beyond formatting.
public enum ZenDoctorReportRenderer {
    public static func render(_ report: ZenDoctorReport) -> String {
        var lines: [String] = []
        lines.append("ZenCODE doctor")
        lines.append("")

        for section in report.sections {
            lines.append("\(section.title):")
            if section.checks.isEmpty {
                lines.append("  (no checks)")
            }
            for check in section.checks {
                lines.append(
                    "  [\(check.status.symbol)] \(check.title): \(check.detail)"
                )
                if let remedy = check.remedy, !remedy.isEmpty {
                    lines.append("      → \(remedy)")
                }
            }
            lines.append("")
        }

        lines.append(summaryLine(for: report))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func summaryLine(for report: ZenDoctorReport) -> String {
        let checks = report.allChecks
        let failures = checks.filter { $0.status == .failure }.count
        let warnings = checks.filter { $0.status == .warning }.count

        if failures > 0 {
            return "Summary: \(failures) failure(s), \(warnings) warning(s). Fix the failures above before running ZenCODE."
        }
        if warnings > 0 {
            return "Summary: no failures, \(warnings) warning(s). ZenCODE can run; review the warnings above."
        }
        return "Summary: all checks passed."
    }
}
