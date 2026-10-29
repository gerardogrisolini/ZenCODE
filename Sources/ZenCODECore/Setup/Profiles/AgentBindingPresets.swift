//
//  AgentBindingPresets.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/10/26.
//
//  Provider-keyed model binding presets read from binding-presets.json.
//

import Foundation
import ToolCore

/// Operator-authored model binding presets, grouped by provider.
///
/// ZenCODE only reads `binding-presets.json`, which ships with the sources in
/// `Sources/ZenPackageMetadata`: it never creates or writes it. The top-level
/// `providers` object is keyed by provider name (the `modelProvider` string of
/// `agents.json`); each provider maps a profile id or role to a block with
/// `modelBindings` and an optional `defaultModelBindingID`. The order of the
/// provider keys in the file is the provider priority.
struct AgentBindingPresets: Equatable, Sendable {
    static let currentVersion = 1
    static let filename = "binding-presets.json"

    /// The bindings one provider grants to one profile.
    struct Block: Decodable, Equatable, Sendable {
        let modelBindings: [AgentModelBinding]
        let defaultModelBindingID: String?
    }

    /// One provider entry, in file order.
    struct Provider: Equatable, Sendable {
        /// The provider key exactly as written in the file.
        let name: String
        /// Blocks keyed by `AgentProfileStore.profileReferenceKey` of the
        /// profile id or role they were written under. Empty keys are dropped;
        /// keys that fold to the same value keep the first one in sorted order.
        let blocksByProfileKey: [String: Block]
    }

    /// Provider entries in the order their keys appear in the file.
    let providers: [Provider]

    init(providers: [Provider]) {
        self.providers = providers
    }

    // MARK: - Decoding

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct File: Decodable {
        let providers: [String: [String: Block]]
    }

    /// Decodes a presets file. Throws `DecodingError` for malformed content and
    /// ``AgentBindingPresetsError/unsupportedVersion`` for another version.
    init(data: Data, url: URL? = nil) throws {
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionProbe.self, from: data).version
        guard version == Self.currentVersion else {
            throw AgentBindingPresetsError.unsupportedVersion(
                url,
                found: version,
                expected: Self.currentVersion
            )
        }
        let file = try decoder.decode(File.self, from: data)

        // The decoded dictionary has no order. The scanner recovers the order
        // of the keys in the file; anything it cannot place (it should not
        // happen once the decoder accepted the data) goes last, sorted.
        var orderedNames = AgentBindingPresetsKeyScanner.keys(
            ofMember: "providers",
            in: data
        ) ?? []
        orderedNames.removeAll { file.providers[$0] == nil }
        let placed = Set(orderedNames)
        orderedNames += file.providers.keys.filter { !placed.contains($0) }.sorted()

        self.providers = orderedNames.map { name in
            Provider(
                name: name,
                blocksByProfileKey: Self.blocksByProfileKey(file.providers[name] ?? [:])
            )
        }
    }

    private static func blocksByProfileKey(
        _ blocks: [String: Block]
    ) -> [String: Block] {
        var result: [String: Block] = [:]
        for rawKey in blocks.keys.sorted() {
            let key = AgentProfileStore.profileReferenceKey(rawKey)
            guard !key.isEmpty, result[key] == nil, let block = blocks[rawKey] else {
                continue
            }
            result[key] = block
        }
        return result
    }

    // MARK: - Loading

    /// Where the presets file sits inside a ZenCODE source checkout.
    static let sourceRelativePath = "Sources/ZenPackageMetadata/" + filename

    /// `binding-presets.json` in the ZenCODE source checkout that `/setup` also
    /// builds ZenCRON and optional features from
    /// (`SwiftFeatureRuntime.zenCODESourceCheckoutURL`: the checkout this binary
    /// was built from, the installer copy under the support directory, then the
    /// working directory). `nil` when no checkout can be located.
    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let checkoutURL = try? SwiftFeatureRuntime.zenCODESourceCheckoutURL(
            fileManager: fileManager
        ) else {
            return nil
        }
        return checkoutURL
            .appendingPathComponent(sourceRelativePath)
            .standardizedFileURL
    }

    /// Reads the presets at `url`. A missing file is not an error: it returns
    /// `nil`. An unreadable file, invalid JSON, or an unsupported version throws
    /// an ``AgentBindingPresetsError`` that names the file.
    static func load(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> AgentBindingPresets? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentBindingPresetsError.unreadableFile(url, error)
        }

        do {
            return try AgentBindingPresets(data: data, url: url)
        } catch let error as AgentBindingPresetsError {
            throw error
        } catch {
            throw AgentBindingPresetsError.invalidFile(url, error)
        }
    }

    // MARK: - Application

    /// The names, exactly as written in the file and in file order, of the
    /// providers that have a block and are among `providerNames` (compared with
    /// `AgentProfileStore.profileReferenceKey`; empty names are ignored).
    func applicableProviderNames(for providerNames: [String]) -> [String] {
        applicableProviders(for: providerNames).map(\.name)
    }

    /// A short report of what `profiles` end up with, such as
    /// "5 bindings on 3 of 8 agents".
    static func outcomeDescription(for profiles: [AgentProfile]) -> String {
        let bindingCount = profiles.reduce(0) { $0 + $1.modelBindings.count }
        let profileCount = profiles.filter { !$0.modelBindings.isEmpty }.count
        return "\(bindingCount) binding\(bindingCount == 1 ? "" : "s") "
            + "on \(profileCount) of \(profiles.count) agent\(profiles.count == 1 ? "" : "s")"
    }

    /// Replaces the model bindings of every profile with the presets of the
    /// given providers; everything else in the profile is untouched.
    ///
    /// - Only provider blocks whose key matches one of `providerNames` count
    ///   (compared with `AgentProfileStore.profileReferenceKey`; empty keys are
    ///   ignored). Callers pass the configured providers.
    /// - In each provider block, in file order, the entry written under the
    ///   profile id wins; the entry written under the profile role is the
    ///   fallback.
    /// - The profile's bindings are those entries' bindings, concatenated. Its
    ///   default is the first non-empty `defaultModelBindingID` in file order.
    /// - The replacement is total: a profile with no applicable entry ends up
    ///   with no bindings and no default.
    ///
    /// `AgentProfile` normalizes the result (invalid and duplicate bindings, an
    /// unknown default); matching bindings against the model catalog is left to
    /// the reconciliation that runs when the profiles are saved.
    func applying(
        to profiles: [AgentProfile],
        configuredProviderNames providerNames: [String]
    ) -> [AgentProfile] {
        let applicable = applicableProviders(for: providerNames)
        return profiles.map { profile in
            let idKey = AgentProfileStore.profileReferenceKey(profile.id)
            let roleKey = AgentProfileStore.profileReferenceKey(profile.role.rawValue)

            var bindings: [AgentModelBinding] = []
            var defaultBindingID: String?
            for provider in applicable {
                guard let block = provider.blocksByProfileKey[idKey]
                    ?? provider.blocksByProfileKey[roleKey] else {
                    continue
                }
                bindings.append(contentsOf: block.modelBindings)
                if defaultBindingID == nil {
                    defaultBindingID = block.defaultModelBindingID?.nilIfBlank
                }
            }
            return ZenCODEAgentProfileSetupRunner.profile(
                basedOn: profile,
                modelBindings: bindings,
                defaultModelBindingID: defaultBindingID
            )
        }
    }

    private func applicableProviders(for providerNames: [String]) -> [Provider] {
        let configuredKeys = Set(
            providerNames
                .map(AgentProfileStore.profileReferenceKey)
                .filter { !$0.isEmpty }
        )
        return providers.filter { provider in
            let key = AgentProfileStore.profileReferenceKey(provider.name)
            return !key.isEmpty && configuredKeys.contains(key)
        }
    }
}

/// Why `binding-presets.json` could not be used.
enum AgentBindingPresetsError: LocalizedError {
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL?, found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(url, error):
            return "Unable to read ZenCODE binding presets file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid ZenCODE binding presets file \(url.path): \(Self.describe(error))"
        case let .unsupportedVersion(url, found, expected):
            let location = url.map { " \($0.path)" } ?? ""
            return "Unsupported ZenCODE binding presets file\(location): version \(found), expected \(expected)"
        }
    }

    /// `DecodingError.localizedDescription` is a generic sentence; the debug
    /// description and coding path say what is wrong and where.
    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        let context: DecodingError.Context
        var path = ""
        switch decodingError {
        case let .typeMismatch(_, decodingContext),
             let .valueNotFound(_, decodingContext),
             let .dataCorrupted(decodingContext):
            context = decodingContext
            path = Self.path(decodingContext.codingPath)
        case let .keyNotFound(key, decodingContext):
            context = decodingContext
            path = Self.path(decodingContext.codingPath + [key])
        @unknown default:
            return error.localizedDescription
        }
        return path.isEmpty
            ? context.debugDescription
            : "\(context.debugDescription) (at \(path))"
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath
            .map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".")
    }
}
