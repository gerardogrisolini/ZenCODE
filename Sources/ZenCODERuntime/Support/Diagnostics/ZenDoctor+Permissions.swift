//
//  ZenDoctor+Permissions.swift
//  ZenCODE
//
//  The permissions section of the doctor report: the local.exec allowlist.
//

import Foundation

extension ZenDoctor {
    // MARK: - Permissions

    static func permissionsSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let permissionsURL = paths.permissions
        let permissionsRead = readPermissionsManifest(at: permissionsURL, fileManager: fileManager)
        switch permissionsRead {
        case let .value(manifest):
            let count = manifest.localExecAllowedCommands.count
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .ok,
                    detail: count == 0
                        ? "No commands are pre-approved for local.exec; each run asks for consent."
                        : "\(count) command pattern(s) are pre-approved for local.exec.",
                    remedy: nil
                )
            )
            checks.append(filePrivacyCheck(
                id: "permissions.filePrivacy",
                title: "permissions.json privacy",
                url: permissionsURL,
                fileManager: fileManager
            ))
        case .invalid:
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .failure,
                    detail: "permissions.json at \(permissionsURL.path) could not be read.",
                    remedy: "Repair or delete permissions.json; it is recreated when you next approve a command."
                )
            )
            checks.append(filePrivacyCheck(
                id: "permissions.filePrivacy",
                title: "permissions.json privacy",
                url: permissionsURL,
                fileManager: fileManager
            ))
        case .missing:
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .info,
                    detail: "No permissions.json yet; local.exec asks for consent on first use.",
                    remedy: nil
                )
            )
        }

        return ZenDoctorSection(title: "Permissions", checks: checks)
    }
}
