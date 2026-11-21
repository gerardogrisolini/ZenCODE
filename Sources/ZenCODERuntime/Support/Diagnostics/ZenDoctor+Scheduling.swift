//
//  ZenDoctor+Scheduling.swift
//  ZenCODE
//
//  The scheduling section of the doctor report: the system tools behind /cron.
//

import Foundation

extension ZenDoctor {
    // MARK: - Scheduled prompts

    /// Reports the system tools behind `/cron`. A missing tool is only a warning:
    /// ZenCODE runs without it, and `/cron` names the exact requirement when used.
    static func schedulingSection(toolchain: ZenCronToolchain) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let crontab = toolchain.crontabPath
        checks.append(
            ZenDoctorCheck(
                id: "scheduling.crontab",
                title: "crontab",
                status: crontab == nil ? .warning : .ok,
                detail: crontab.map { "Found at \($0)." } ?? "Not found.",
                remedy: crontab == nil
                    ? "Install cron to schedule prompts with /cron."
                    : nil
            )
        )

        // cron delivers job output through sendmail; without it results are lost.
        let sendmail = toolchain.sendmailPath
        checks.append(
            ZenDoctorCheck(
                id: "scheduling.sendmail",
                title: "sendmail",
                status: sendmail == nil ? .warning : .ok,
                detail: sendmail.map { "Found at \($0)." }
                    ?? "Not found; cron cannot mail scheduled prompt results.",
                remedy: sendmail == nil
                    ? "Install an MTA such as postfix, exim or msmtp."
                    : nil
            )
        )

        #if os(Linux)
        if isWindowsSubsystemForLinux() {
            checks.append(
                ZenDoctorCheck(
                    id: "scheduling.wsl",
                    title: "WSL cron service",
                    status: .warning,
                    detail: "WSL does not start the cron service automatically",
                    remedy: "Run `sudo service cron start` or enable systemd in /etc/wsl.conf."
                )
            )
        }
        #endif

        return ZenDoctorSection(title: "Scheduled prompts", checks: checks)
    }
}
