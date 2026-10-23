//
//  SherpaOnnxVoiceInstallation.swift
//  ZenCODE
//
//  Layout of the downloaded Linux voice-mode files under
//  `<support directory>/voice`. Each asset is installed atomically (staged,
//  verified, then moved into place), so the presence of an asset's directory
//  or file means it is complete. Exactly one Piper voice is kept installed.
//

import Foundation

/// The files voice mode runs with, resolved from a complete installation.
struct SherpaOnnxRuntimePaths: Sendable, Equatable {
    let recognizerProgram: URL
    let synthesizerProgram: URL
    let voiceActivityModel: URL
    let encoder: URL
    let decoder: URL
    let joiner: URL
    let recognizerTokens: URL
    let voice: SherpaOnnxVoice
    let voiceModel: URL
    let voiceTokens: URL
    let voiceDataDirectory: URL
}

struct SherpaOnnxVoiceInstallation: Sendable {
    static let directoryName = "voice"
    /// Download and extraction scratch space, removed after every install.
    static let stagingDirectoryName = ".staging"

    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// `<support directory>/voice`, honouring `ZENCODE_SUPPORT_DIRECTORY`.
    static func standard() -> SherpaOnnxVoiceInstallation {
        SherpaOnnxVoiceInstallation(
            directoryURL: ZenFileService.supportDirectoryURL()
                .appendingPathComponent(directoryName, isDirectory: true)
        )
    }

    var stagingDirectoryURL: URL {
        directoryURL.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    func installedURL(for asset: SherpaOnnxAsset) -> URL {
        directoryURL.appendingPathComponent(asset.installedName)
    }

    func isInstalled(_ asset: SherpaOnnxAsset) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: installedURL(for: asset).path,
            isDirectory: &isDirectory
        ) else {
            return false
        }
        switch asset.kind {
        case .archive:
            return isDirectory.boolValue
        case .file:
            return !isDirectory.boolValue
        }
    }

    /// Catalog voices currently installed, in catalog order.
    func installedVoices() -> [SherpaOnnxVoice] {
        SherpaOnnxVoiceCatalog.voices.filter { isInstalled($0.asset) }
    }

    var hasInstalledFiles: Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return entries.contains { $0 != Self.stagingDirectoryName }
    }

    /// Assets still to download before `voice` can run. `nil` when this
    /// architecture has no prebuilt programs.
    func missingAssets(for voice: SherpaOnnxVoice) -> [SherpaOnnxAsset]? {
        guard let shared = SherpaOnnxVoiceCatalog.sharedAssets() else {
            return nil
        }
        return (shared + [voice.asset]).filter { !isInstalled($0) }
    }

    /// Paths for running voice mode, or the reason it cannot run yet.
    func runtimePaths() -> Result<SherpaOnnxRuntimePaths, SherpaOnnxVoiceInstallError> {
        guard let runtime = SherpaOnnxVoiceCatalog.runtime else {
            return .failure(.unsupportedArchitecture)
        }
        guard let voice = installedVoices().first,
              isInstalled(runtime),
              isInstalled(SherpaOnnxVoiceCatalog.recognizer),
              isInstalled(SherpaOnnxVoiceCatalog.voiceActivityDetector) else {
            return .failure(.notInstalled)
        }
        let bin = installedURL(for: runtime).appendingPathComponent("bin", isDirectory: true)
        let recognizerDirectory = installedURL(for: SherpaOnnxVoiceCatalog.recognizer)
        let voiceDirectory = installedURL(for: voice.asset)
        guard let voiceModel = Self.singleModelFile(in: voiceDirectory) else {
            return .failure(.unexpectedLayout(voice.asset.fileName))
        }
        let paths = SherpaOnnxRuntimePaths(
            recognizerProgram: bin.appendingPathComponent(SherpaOnnxVoiceCatalog.recognizerProgramName),
            synthesizerProgram: bin.appendingPathComponent(SherpaOnnxVoiceCatalog.synthesizerProgramName),
            voiceActivityModel: installedURL(for: SherpaOnnxVoiceCatalog.voiceActivityDetector),
            encoder: recognizerDirectory.appendingPathComponent(SherpaOnnxVoiceCatalog.recognizerEncoderFileName),
            decoder: recognizerDirectory.appendingPathComponent(SherpaOnnxVoiceCatalog.recognizerDecoderFileName),
            joiner: recognizerDirectory.appendingPathComponent(SherpaOnnxVoiceCatalog.recognizerJoinerFileName),
            recognizerTokens: recognizerDirectory.appendingPathComponent(SherpaOnnxVoiceCatalog.tokensFileName),
            voice: voice,
            voiceModel: voiceModel,
            voiceTokens: voiceDirectory.appendingPathComponent(SherpaOnnxVoiceCatalog.tokensFileName),
            voiceDataDirectory: voiceDirectory.appendingPathComponent(
                SherpaOnnxVoiceCatalog.voiceDataDirectoryName,
                isDirectory: true
            )
        )
        let fileManager = FileManager.default
        for program in [paths.recognizerProgram, paths.synthesizerProgram]
        where !fileManager.isExecutableFile(atPath: program.path) {
            return .failure(.unexpectedLayout(runtime.fileName))
        }
        for file in [paths.encoder, paths.decoder, paths.joiner, paths.recognizerTokens]
        where !fileManager.fileExists(atPath: file.path) {
            return .failure(.unexpectedLayout(SherpaOnnxVoiceCatalog.recognizer.fileName))
        }
        for file in [paths.voiceTokens, paths.voiceDataDirectory]
        where !fileManager.fileExists(atPath: file.path) {
            return .failure(.unexpectedLayout(voice.asset.fileName))
        }
        return .success(paths)
    }

    /// The only `.onnx` file of a Piper voice directory.
    static func singleModelFile(in directory: URL) -> URL? {
        let models = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".onnx") }
        guard models.count == 1 else {
            return nil
        }
        return directory.appendingPathComponent(models[0])
    }
}

enum SherpaOnnxVoiceInstallError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case notInstalled
    case missingTool(String)
    case httpStatus(Int)
    case sizeMismatch(fileName: String, expected: Int64, actual: Int64)
    case checksumMismatch(fileName: String)
    case extractionFailed(fileName: String, reason: String)
    case unexpectedLayout(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "No prebuilt sherpa-onnx programs exist for this processor architecture."
        case .notInstalled:
            return "Voice mode files are not installed. Run /setup and choose Voice mode to download them."
        case let .missingTool(tool):
            return "The \(tool) program is required to unpack the voice mode files. Install it with your package manager and try again."
        case let .httpStatus(status):
            return "The download failed with HTTP status \(status)."
        case let .sizeMismatch(fileName, expected, actual):
            return "\(fileName) has \(actual) bytes instead of the expected \(expected); it was not installed."
        case let .checksumMismatch(fileName):
            return "\(fileName) does not match its pinned SHA-256 checksum; it was not installed."
        case let .extractionFailed(fileName, reason):
            return "\(fileName) could not be unpacked: \(reason)"
        case let .unexpectedLayout(fileName):
            return "\(fileName) does not contain the expected files. Reinstall it from /setup > Voice mode."
        }
    }
}
