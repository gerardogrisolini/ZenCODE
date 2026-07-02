//
//  MLXServerSetupRunner+Menu.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore
import MLXServerCore

extension MLXServerSetupRunner {
    static func promptSetupSection(
        currentSettings settings: MLXServerSettings,
        settingsExists: Bool
    ) throws -> SetupSection {
                let options = setupSectionOptions(currentSettings: settings)
        let defaultSection: SetupSection = settingsExists ? .finish : .kvCache
        let defaultIndex = options.firstIndex { $0.section == defaultSection } ?? 0

        let items = options.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.section.title,
                detail: option.detail
            )
        }
        let choice = TerminalCheckboxMenu.selectOne(
            title: "MLX setup sections",
            items: items,
            selected: defaultIndex
        ) ?? defaultIndex
        return options[choice].section
    }

    static func setupSectionOptions(
        currentSettings settings: MLXServerSettings
    ) -> [SetupSectionOption] {
        [
            SetupSectionOption(
                section: .kvCache,
                detail: kvCacheSetupDetail(settings.kvCache)
            ),
            SetupSectionOption(
                section: .diskKVCache,
                detail: diskKVCacheSetupDetail(settings.diskKVCache)
            ),
            SetupSectionOption(section: .finish, detail: "save and exit"),
            SetupSectionOption(section: .cancel, detail: "discard changes")
        ]
    }

    static func kvCacheSetupDetail(_ settings: MLXServerKVCacheSettings) -> String {
        let settings = settings.validated()
        if let profile = KVCacheProfile.matching(settings) {
            return profile.title
        }
        switch settings.mode {
        case .standard:
            return "standard"
        case .quantized:
            return "quantized \(settings.quantizedBits)-bit, group \(settings.quantizedGroupSize), start \(settings.quantizedStart)"
        }
    }

    static func diskKVCacheSetupDetail(_ settings: MLXServerDiskKVCacheSettings) -> String {
        guard settings.enabled else {
            return "disabled"
        }
        let limit = settings.limitGB.map { String(format: "%.0f GB", $0) } ?? "no limit"
        if let directoryPath = settings.directoryPath?.nilIfEmpty {
            return "enabled, \(limit), \(directoryPath)"
        }
        return "enabled, \(limit), default directory"
    }

    static func configureSetupSection(
        _ section: SetupSection,
        currentSettings settings: MLXServerSettings
    ) throws -> MLXServerSettings {
                switch section {
        case .kvCache:
            return try configureKVCache(settings)
        case .diskKVCache:
            return try configureDiskKVCache(settings)
        case .finish, .cancel:
            return settings
        }
    }

}
