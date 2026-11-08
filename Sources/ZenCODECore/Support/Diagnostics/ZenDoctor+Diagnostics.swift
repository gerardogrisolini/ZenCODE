//
//  ZenDoctor+Diagnostics.swift
//  ZenCODE
//
//  The diagnostics section of the doctor report: logging configuration.
//

import Foundation
import ToolCore

extension ZenDoctor {
    // MARK: - Diagnostics logging

    static func diagnosticsSection(
        environment: [String: String]
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        // Resolve the logger configuration directly from the environment rather
        // than consulting ZenLogger.isEnabled. Resolution is pure (the system
        // log is opened lazily by the platform), so the doctor stays read-only
        // even when logging is enabled, without ever touching stdout.
        if let configuration = ZenLogger.previewConfiguration(environment: environment) {
            let level = configuration.minimumLevel.label
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.logging",
                    title: "Diagnostic logging",
                    status: .info,
                    detail: "Enabled at level \(level); output is redacted and written to the \(configuration.destinationDescription) (subsystem \(SystemLogEmitter.subsystem)).",
                    remedy: "Unset ZENCODE_LOG to disable diagnostic logging."
                )
            )
        } else {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.logging",
                    title: "Diagnostic logging",
                    status: .info,
                    detail: "Disabled (default). No diagnostic output is produced and stdout stays clean.",
                    remedy: "Set ZENCODE_LOG=debug to emit redacted diagnostics to the system log (view it with /tools logs)."
                )
            )
        }

        // Legacy destination variables no longer do anything; surface them so a
        // stale configuration is not mistaken for working diagnostics.
        if environment["ZENCODE_LOG_FILE"]?.nilIfBlank != nil {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.loggingLegacyFile",
                    title: "Legacy diagnostic log file",
                    status: .warning,
                    detail: "ZENCODE_LOG_FILE is set, but diagnostics no longer write to an application-owned file; the value is ignored.",
                    remedy: "Unset ZENCODE_LOG_FILE. Set ZENCODE_LOG to a level to emit redacted diagnostics to the system log."
                )
            )
        }
        if let rawEnable = environment["ZENCODE_LOG"]?.nilIfBlank,
            ZenLoggerConfiguration.isLegacyDestinationValue(rawEnable.lowercased()) {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.loggingLegacyDestination",
                    title: "Invalid ZENCODE_LOG value",
                    status: .warning,
                    detail: "ZENCODE_LOG=\(rawEnable) named the removed stderr destination, so diagnostic logging stays disabled.",
                    remedy: "Set ZENCODE_LOG to a level such as debug to emit redacted diagnostics to the system log."
                )
            )
        }

        return ZenDoctorSection(title: "Diagnostics", checks: checks)
    }
}
