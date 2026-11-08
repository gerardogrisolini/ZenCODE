//
//  ZenDoctor+SupportFiles.swift
//  ZenCODE
//
//  The support-files section of the doctor report: the support directory and its permissions.
//

import Foundation

extension ZenDoctor {
    // MARK: - Support files

    static func supportFilesSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let supportDirectory = paths.supportDirectory
        let supportExists = directoryExists(supportDirectory, fileManager: fileManager)
        checks.append(
            ZenDoctorCheck(
                id: "support.directory",
                title: "Support directory",
                status: supportExists ? .ok : .warning,
                detail: supportExists
                    ? "Present at \(supportDirectory.path)."
                    : "Not created yet at \(supportDirectory.path).",
                remedy: supportExists
                    ? nil
                    : "Run zen --setup; it creates ~/.zencode and its base files."
            )
        )

        if supportExists {
            checks.append(directoryWritabilityCheck(supportDirectory, fileManager: fileManager))
        }

        return ZenDoctorSection(title: "Support files", checks: checks)
    }

    private static func directoryWritabilityCheck(
        _ directory: URL,
        fileManager: FileManager
    ) -> ZenDoctorCheck {
        let writable = fileManager.isWritableFile(atPath: directory.path)
        return ZenDoctorCheck(
            id: "support.writable",
            title: "Support directory permissions",
            status: writable ? .ok : .failure,
            detail: writable
                ? "The support directory is writable."
                : "The support directory at \(directory.path) is not writable.",
            remedy: writable
                ? nil
                : "Fix the ownership/permissions of the support directory so the current user can write to it."
        )
    }
}
