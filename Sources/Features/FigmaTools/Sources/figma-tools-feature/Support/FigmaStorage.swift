//
//  FigmaStorage.swift
//  ZenCODE
//
//  Locations owned by the Figma feature inside the ZenCODE support
//  directory (`~/.zencode`, or the directory ZenCODE itself was started
//  with): the login credential store and rendered image artifacts.
//

import Foundation
import ToolCore

enum FigmaStorage {
    /// ZenCODE's own support-directory override, honored so the feature keeps
    /// its data next to the ZenCODE instance that launched it.
    static let supportDirectoryEnvironmentKey = "ZENCODE_SUPPORT_DIRECTORY"

    static func supportDirectoryURL(environment: [String: String]) -> URL {
        if let configured = environment[supportDirectoryEnvironmentKey]?.nilIfBlank {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        let home: URL
        if let path = environment["HOME"]?.nilIfBlank {
            home = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".zencode", isDirectory: true).standardizedFileURL
    }

    static func featureDirectoryURL(environment: [String: String]) -> URL {
        supportDirectoryURL(environment: environment).appendingPathComponent("figma", isDirectory: true)
    }

    /// `<support>/figma/credentials/login.json`, written by the login flow only.
    static func credentialFileURL(environment: [String: String]) -> URL {
        featureDirectoryURL(environment: environment)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("login.json", isDirectory: false)
    }

    /// Private directory for rendered images handed to the host as attachments.
    static func artifactDirectoryURL(environment: [String: String]) throws -> URL {
        let directory = featureDirectoryURL(environment: environment)
            .appendingPathComponent("artifacts", isDirectory: true)
        try createPrivateDirectory(directory)
        return directory.standardizedFileURL
    }

    static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
