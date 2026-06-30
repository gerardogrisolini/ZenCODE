//
//  ZenPackageMetadata.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

public enum ZenPackageMetadata {
    public static let packageName = "ZenCODE"
    public static let coderExecutableName = "zen"
    public static let version = "0.1.0"

    public static func versionDescription(for executableName: String) -> String {
        "\(executableName) \(version)"
    }
}

