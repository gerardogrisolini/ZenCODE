//
//  MLXServerSetupRunner+KVCache.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import ZenCODECore
import MLXServerCore

extension MLXServerSetupRunner {
    static func configureKVCache(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let kvCache = try promptKVCacheSettings(defaultSettings: settings.kvCache)
        return try settingsByUpdating(settings, kvCache: kvCache)
    }

    static func configureDiskKVCache(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let diskKVCacheEnabled = try promptYesNo(
            "Enable disk KV cache?",
            defaultValue: settings.diskKVCache.enabled
        )
        let diskKVCache: MLXServerDiskKVCacheSettings
        if diskKVCacheEnabled {
            let defaultDirectory = MLXServerDiskKVCacheConfiguration.defaultDirectory().path
            let useCustomDirectory = try promptYesNo(
                "Use a custom KV cache directory?",
                defaultValue: settings.diskKVCache.directoryPath != nil
            )
            let directoryPath: String?
            if useCustomDirectory {
                directoryPath = try promptString(
                    "KV cache directory",
                    defaultValue: settings.diskKVCache.directoryPath ?? defaultDirectory,
                    allowEmpty: false,
                    maximumLength: MLXServerSetupInputParser.maximumPathLength
                )
            } else {
                directoryPath = nil
            }
            let limitGB = try promptDouble(
                "Disk KV cache limit in GB",
                defaultValue: settings.diskKVCache.limitGB ?? 100,
                allowedRange: 0...MLXServerDiskKVCacheSettings.maximumLimitGB
            )
            diskKVCache = MLXServerDiskKVCacheSettings(
                enabled: true,
                directoryPath: directoryPath,
                limitGB: limitGB
            )
        } else {
            diskKVCache = MLXServerDiskKVCacheSettings(enabled: false)
        }
        return try settingsByUpdating(settings, diskKVCache: diskKVCache)
    }

    static func kvCacheProfileDetail(_ profile: KVCacheProfile) -> String {
        switch profile {
        case .bestPerformance:
            return "standard full precision cache"
        case .balanced:
            return "quantized after 1024 tokens"
        case .lowMemory:
            return "quantized immediately"
        case .longSessions:
            return "quantized after 2048 tokens"
        case .custom:
            return "manually set mode, bits, group size, and start"
        }
    }

    static func settingsByUpdating(
        _ settings: MLXServerSettings,
        kvCache: MLXServerKVCacheSettings? = nil,
        diskKVCache: MLXServerDiskKVCacheSettings? = nil
    ) throws -> MLXServerSettings {
        try MLXServerSettings(
            host: settings.host,
            port: settings.port,
            webServerThreadCount: settings.webServerThreadCount,
            http2PriorKnowledge: settings.http2PriorKnowledge,
            apiKey: settings.apiKey,
            tlsCertificatePath: settings.tlsCertificatePath,
            tlsPrivateKeyPath: settings.tlsPrivateKeyPath,
            metricsLogPath: settings.metricsLogPath,
            kvCache: kvCache ?? settings.kvCache,
            diskKVCache: diskKVCache ?? settings.diskKVCache,
            huggingFaceCache: settings.huggingFaceCache
        ).validated()
    }

    static func promptKVCacheSettings(
        defaultSettings: MLXServerKVCacheSettings
    ) throws -> MLXServerKVCacheSettings {
                let defaultProfile = KVCacheProfile.matching(defaultSettings.validated()) ?? .custom
        let selectedProfile = TerminalCheckboxMenu.selectOne(
            title: "In-memory KV cache",
            items: KVCacheProfile.allCases.map { profile in
                TerminalCheckboxMenuItem(
                    value: profile.rawValue,
                    title: profile.title,
                    detail: kvCacheProfileDetail(profile)
                )
            },
            selected: defaultProfile.rawValue
        ) ?? defaultProfile.rawValue

        guard let profile = KVCacheProfile(rawValue: selectedProfile) else {
            return defaultSettings.validated()
        }


        switch profile {
        case .bestPerformance, .balanced, .lowMemory, .longSessions:
            return profile.presetSettings ?? defaultSettings.validated()
        case .custom:
            let useQuantized = try promptYesNo(
                "Use quantized KV cache?",
                defaultValue: defaultSettings.mode == .quantized
            )
            guard useQuantized else {
                return MLXServerKVCacheSettings(
                    mode: .standard,
                    quantizedBits: defaultSettings.quantizedBits,
                    quantizedGroupSize: defaultSettings.quantizedGroupSize,
                    quantizedStart: defaultSettings.quantizedStart
                ).validated()
            }

            let quantizedBits = try promptInt(
                "KV quantized bits",
                defaultValue: defaultSettings.quantizedBits,
                allowedRange: 2...8
            )
            let quantizedGroupSize = try promptInt(
                "KV quantized group size",
                defaultValue: defaultSettings.quantizedGroupSize,
                allowedRange: 1...256
            )
            let quantizedStart = try promptInt(
                "Quantized start token",
                defaultValue: defaultSettings.quantizedStart,
                allowedRange: 0...262_144
            )
            return MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedBits: quantizedBits,
                quantizedGroupSize: quantizedGroupSize,
                quantizedStart: quantizedStart
            ).validated()
        }
    }

}
