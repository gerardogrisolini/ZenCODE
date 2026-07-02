//
//  MLXServerSettings.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation

public struct MLXServerSettings: Codable, Equatable, Sendable {
    public static let defaultWebServerThreadCount = 2
    public static let maximumWebServerThreadCount = 256

    public var host: String
    public var port: Int
    public var webServerThreadCount: Int
    public var http2PriorKnowledge: Bool
    public var apiKey: String?
    public var tlsCertificatePath: String?
    public var tlsPrivateKeyPath: String?
    public var metricsLogPath: String?
    public var kvCache: MLXServerKVCacheSettings
    public var diskKVCache: MLXServerDiskKVCacheSettings
    public var huggingFaceCache: MLXServerHuggingFaceCacheSettings

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case webServerThreadCount = "web_server_threads"
        case http2PriorKnowledge = "http2_prior_knowledge"
        case apiKey = "api_key"
        case tlsCertificatePath = "tls_certificate_path"
        case tlsPrivateKeyPath = "tls_private_key_path"
        case metricsLogPath = "metrics_log_path"
        case kvCache = "kv_cache"
        case diskKVCache = "disk_kv_cache"
        case huggingFaceCache = "huggingface_cache"
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        webServerThreadCount: Int = Self.defaultWebServerThreadCount,
        http2PriorKnowledge: Bool = false,
        apiKey: String? = nil,
        tlsCertificatePath: String? = nil,
        tlsPrivateKeyPath: String? = nil,
        metricsLogPath: String? = nil,
        kvCache: MLXServerKVCacheSettings = .init(),
        diskKVCache: MLXServerDiskKVCacheSettings = .init(),
        huggingFaceCache: MLXServerHuggingFaceCacheSettings = .init()
    ) {
        self.host = host
        self.port = port
        self.webServerThreadCount = webServerThreadCount
        self.http2PriorKnowledge = http2PriorKnowledge
        self.apiKey = apiKey
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.metricsLogPath = metricsLogPath
        self.kvCache = kvCache
        self.diskKVCache = diskKVCache
        self.huggingFaceCache = huggingFaceCache
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        webServerThreadCount = try container.decodeIfPresent(
            Int.self,
            forKey: .webServerThreadCount
        ) ?? Self.defaultWebServerThreadCount
        http2PriorKnowledge = try container.decodeIfPresent(
            Bool.self,
            forKey: .http2PriorKnowledge
        ) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        tlsCertificatePath = try container.decodeIfPresent(String.self, forKey: .tlsCertificatePath)
        tlsPrivateKeyPath = try container.decodeIfPresent(String.self, forKey: .tlsPrivateKeyPath)
        metricsLogPath = try container.decodeIfPresent(String.self, forKey: .metricsLogPath)
        kvCache = try container.decodeIfPresent(
            MLXServerKVCacheSettings.self,
            forKey: .kvCache
        ) ?? .init()
        diskKVCache = try container.decodeIfPresent(
            MLXServerDiskKVCacheSettings.self,
            forKey: .diskKVCache
        ) ?? .init()
        huggingFaceCache = try container.decodeIfPresent(
            MLXServerHuggingFaceCacheSettings.self,
            forKey: .huggingFaceCache
        ) ?? .init()
    }

    public func validated() throws -> Self {
        let configuration = try MLXServerConfiguration(host: host, port: port).validated()
        guard (1...Self.maximumWebServerThreadCount).contains(webServerThreadCount) else {
            throw MLXServerSettingsError.invalidWebServerThreadCount(webServerThreadCount)
        }
        let normalizedTLSCertificatePath = tlsCertificatePath?.trimmedNonEmpty
        let normalizedTLSPrivateKeyPath = tlsPrivateKeyPath?.trimmedNonEmpty
        if (normalizedTLSCertificatePath == nil) != (normalizedTLSPrivateKeyPath == nil) {
            throw MLXServerSettingsError.incompleteTLSConfiguration
        }

        return Self(
            host: configuration.host,
            port: configuration.port,
            webServerThreadCount: webServerThreadCount,
            http2PriorKnowledge: http2PriorKnowledge,
            apiKey: apiKey?.trimmedNonEmpty,
            tlsCertificatePath: normalizedTLSCertificatePath,
            tlsPrivateKeyPath: normalizedTLSPrivateKeyPath,
            metricsLogPath: metricsLogPath?.trimmedNonEmpty,
            kvCache: kvCache.validated(),
            diskKVCache: try diskKVCache.validated(),
            huggingFaceCache: huggingFaceCache.validated()
        )
    }

    public var serverConfiguration: MLXServerConfiguration {
        MLXServerConfiguration(host: host, port: port)
    }
}

public enum MLXServerKVCacheMode: String, Codable, CaseIterable, Sendable {
    case standard
    case quantized
}

public struct MLXServerKVCacheSettings: Codable, Equatable, Sendable {
    public static let defaultQuantizedBits = 4
    public static let defaultQuantizedGroupSize = 64
    public static let defaultQuantizedStart = 1_024

    public var mode: MLXServerKVCacheMode
    public var quantizedBits: Int
    public var quantizedGroupSize: Int
    public var quantizedStart: Int

    private enum CodingKeys: String, CodingKey {
        case mode
        case quantizedBits = "quantized_bits"
        case quantizedGroupSize = "quantized_group_size"
        case quantizedStart = "quantized_start"
    }

    public init(
        mode: MLXServerKVCacheMode = .standard,
        quantizedBits: Int = Self.defaultQuantizedBits,
        quantizedGroupSize: Int = Self.defaultQuantizedGroupSize,
        quantizedStart: Int = Self.defaultQuantizedStart
    ) {
        self.mode = mode
        self.quantizedBits = quantizedBits
        self.quantizedGroupSize = quantizedGroupSize
        self.quantizedStart = quantizedStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(MLXServerKVCacheMode.self, forKey: .mode) ?? .standard
        quantizedBits = try container.decodeIfPresent(Int.self, forKey: .quantizedBits)
            ?? Self.defaultQuantizedBits
        quantizedGroupSize = try container.decodeIfPresent(Int.self, forKey: .quantizedGroupSize)
            ?? Self.defaultQuantizedGroupSize
        quantizedStart = try container.decodeIfPresent(Int.self, forKey: .quantizedStart)
            ?? Self.defaultQuantizedStart
    }

    public func validated() -> Self {
        Self(
            mode: mode,
            quantizedBits: min(max(quantizedBits, 2), 8),
            quantizedGroupSize: min(max(quantizedGroupSize, 1), 256),
            quantizedStart: min(max(quantizedStart, 0), 262_144)
        )
    }

    public var kvBits: Int? {
        mode == .quantized ? quantizedBits : nil
    }

    public var kvGroupSize: Int? {
        mode == .quantized ? quantizedGroupSize : nil
    }

    public var quantizedKVStart: Int? {
        mode == .quantized ? quantizedStart : nil
    }
}

public struct MLXServerHuggingFaceCacheSettings: Codable, Equatable, Sendable {
    public var directoryPath: String?
    public var bookmark: String?

    private enum CodingKeys: String, CodingKey {
        case directoryPath = "directory_path"
        case bookmark
    }

    public init(
        directoryPath: String? = nil,
        bookmark: String? = nil
    ) {
        self.directoryPath = directoryPath
        self.bookmark = bookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        bookmark = try container.decodeIfPresent(String.self, forKey: .bookmark)
    }

    public func validated() -> Self {
        Self(
            directoryPath: directoryPath?.trimmedNonEmpty,
            bookmark: bookmark?.trimmedNonEmpty
        )
    }

    public var bookmarkData: Data? {
        guard let bookmark else {
            return nil
        }
        return Data(base64Encoded: bookmark)
    }
}

public struct MLXServerDiskKVCacheSettings: Codable, Equatable, Sendable {
    public static let maximumLimitGB: Double = 1_000_000

    public var enabled: Bool
    public var directoryPath: String?
    public var limitGB: Double?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case directoryPath = "directory_path"
        case limitGB = "limit_gb"
    }

    public init(
        enabled: Bool = true,
        directoryPath: String? = nil,
        limitGB: Double? = 100
    ) {
        self.enabled = enabled
        self.directoryPath = directoryPath
        self.limitGB = limitGB
    }

    public func validated() throws -> Self {
        let normalizedDirectoryPath = directoryPath?.trimmedNonEmpty
        if let limitGB,
           !limitGB.isFinite || !(0...Self.maximumLimitGB).contains(limitGB) {
            throw MLXServerSettingsError.invalidDiskKVCacheLimit
        }
        return Self(
            enabled: enabled,
            directoryPath: normalizedDirectoryPath,
            limitGB: limitGB
        )
    }

    public var configuration: MLXServerDiskKVCacheConfiguration {
        guard enabled else {
            return .disabled
        }

        let directory = directoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let limitBytes = limitGB.map { gb in
            guard gb.isFinite, gb > 0 else {
                return Int64(0)
            }
            let clampedGB = min(gb, Self.maximumLimitGB)
            return Int64(clampedGB * 1024 * 1024 * 1024)
        }

        return MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: limitBytes ?? MLXServerDiskKVCacheConfiguration.defaultLimitBytes
        )
    }
}

public enum MLXServerSettingsStore {
    public static let settingsFilename = "settings.json"

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    public static func supportDirectoryURL(fileManager: FileManager = .default) -> URL {
        defaultSupportDirectoryURL(fileManager: fileManager)
    }

    public static func defaultSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        MLXServerUserHomeDirectory.current(fileManager: fileManager)
            .appendingPathComponent(".zencode", isDirectory: true)
            .appendingPathComponent("mlx", isDirectory: true)
            .standardizedFileURL
    }

    public static func loadRequired(
        from url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) throws -> MLXServerSettings {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MLXServerSettingsError.missingSettings(url)
        }
        return try loadSettings(from: url).validated()
    }

    public static func save(
        _ settings: MLXServerSettings,
        to url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(try settings.validated())
        try data.write(to: url, options: [.atomic])
    }

    public static func loadOrDefault(
        from url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) -> MLXServerSettings {
        (try? loadRequired(from: url, fileManager: fileManager)) ?? MLXServerSettings()
    }

    public static func saveHuggingFaceCacheAccess(
        cacheDirectoryPath: String,
        bookmarkData: Data?,
        fileManager: FileManager = .default
    ) throws {
        var settings = loadOrDefault(fileManager: fileManager)
        settings.huggingFaceCache = MLXServerHuggingFaceCacheSettings(
            directoryPath: cacheDirectoryPath,
            bookmark: bookmarkData?.base64EncodedString()
        )
        try save(settings, fileManager: fileManager)
    }

    public static func clearHuggingFaceCacheAccess(
        fileManager: FileManager = .default
    ) {
        var settings = loadOrDefault(fileManager: fileManager)
        settings.huggingFaceCache = MLXServerHuggingFaceCacheSettings()
        try? save(settings, fileManager: fileManager)
    }

    private static func loadSettings(from url: URL) throws -> MLXServerSettings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MLXServerSettings.self, from: data)
    }
}

public enum MLXServerSettingsError: LocalizedError, Equatable, Sendable {
    case missingSettings(URL)
    case incompleteTLSConfiguration
    case invalidDiskKVCacheLimit
    case invalidWebServerThreadCount(Int)

    public var errorDescription: String? {
        switch self {
        case .missingSettings(let url):
            return "settings.json not found at \(url.path). Run zen --setup and choose local MLX runtime setup first."
        case .incompleteTLSConfiguration:
            return "TLS requires both certificate and private key paths."
        case .invalidDiskKVCacheLimit:
            return "Disk KV cache limit must be between 0 and 1,000,000 GB."
        case .invalidWebServerThreadCount(let value):
            return "Web server thread count \(value) is outside the supported range."
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
