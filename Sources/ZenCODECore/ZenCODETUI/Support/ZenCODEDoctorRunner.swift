//
//  ZenCODEDoctorRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Non-interactive `zen --doctor` command.
///
/// It prints a redacted, secret-free diagnostic report to stdout, never starts
/// setup, never mutates configuration, and exits with a non-zero status only
/// when a blocking failure is found so it is scriptable.
public enum ZenCODEDoctorRunner {
    public static let option = "--doctor"
    public static let troubleshootingHint =
        "Run 'zen --doctor' for a redacted diagnostic report; set ZENCODE_LOG=debug to capture local logs.\n"

    /// Whether the sanitized arguments request the doctor command.
    public static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    /// Builds and prints the report. Returns the process exit code.
    @discardableResult
    public static func run() -> Int32 {
        let report = ZenDoctor.runReport()
        let text = ZenDoctorReportRenderer.render(report)
        AgentOutput.standardOutput.writeString(text)
        return report.exitCode
    }
}
