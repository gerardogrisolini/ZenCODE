//
//  ZenDoctor+Environment.swift
//  ZenCODE
//
//  The environment section of the doctor report: platform, version and home directory.
//

import Foundation
import ToolCore
import ZenPackageMetadata

extension ZenDoctor {
    // MARK: - Environment

    static func environmentSection(environment: [String: String]) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        checks.append(
            ZenDoctorCheck(
                id: "environment.platform",
                title: "Operating system",
                status: .info,
                detail: platformDescription()
            )
        )

        checks.append(
            ZenDoctorCheck(
                id: "environment.version",
                title: "ZenCODE version",
                status: .info,
                detail: ZenPackageMetadata.version
            )
        )

        // Home directory must be resolvable for the support directory to exist.
        let home = UserHomeDirectory.current()
        let homeExists = directoryExists(home)
        checks.append(
            ZenDoctorCheck(
                id: "environment.home",
                title: "Home directory",
                status: homeExists ? .ok : .failure,
                detail: homeExists
                    ? "Resolved home directory at \(home.path)."
                    : "Home directory \(home.path) does not exist or is not a directory.",
                remedy: homeExists
                    ? nil
                    : "Ensure the current user has a valid home directory; ZenCODE stores its configuration under ~/.zencode."
            )
        )

        // A support-directory override is a common source of confusion.
        if let override = environment[AppStorageDirectory.supportDirectoryEnvironmentKey]?.nilIfBlank {
            checks.append(
                ZenDoctorCheck(
                    id: "environment.supportOverride",
                    title: "Support directory override",
                    status: .info,
                    detail: "\(AppStorageDirectory.supportDirectoryEnvironmentKey) is set to \(override).",
                    remedy: "Unset \(AppStorageDirectory.supportDirectoryEnvironmentKey) to use the default ~/.zencode."
                )
            )
        }

        return ZenDoctorSection(title: "Environment", checks: checks)
    }
}
