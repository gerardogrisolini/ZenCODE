//
//  MLXServerCore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Foundation
import ZenPackageMetadata

public enum MLXServerCore {
    public static let serviceName = "MLX"
    public static let version = ZenPackageMetadata.version
    public static let versionDescription = ZenPackageMetadata.versionDescription(
        for: serviceName
    )
}

public struct MLXServerConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080
    ) {
        self.host = host
        self.port = port
    }

    public func validated() throws -> Self {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw MLXServerConfigurationError.emptyHost
        }
        guard (1 ... Int(UInt16.max)).contains(port) else {
            throw MLXServerConfigurationError.invalidPort(port)
        }
        return MLXServerConfiguration(host: normalizedHost, port: port)
    }
}

public enum MLXServerConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyHost
    case invalidPort(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            return "Host can not be empty."
        case let .invalidPort(port):
            return "Port \(port) is outside the valid TCP range."
        }
    }
}
