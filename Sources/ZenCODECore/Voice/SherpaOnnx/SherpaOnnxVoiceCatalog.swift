//
//  SherpaOnnxVoiceCatalog.swift
//  ZenCODE
//
//  Pinned downloads of the Linux voice mode. Voice mode on Linux runs the
//  sherpa-onnx command-line programs as external processes: speech
//  recognition with the Parakeet TDT 0.6B v3 model behind a Silero voice
//  activity detector, and spoken answers with a Piper voice. Nothing here is
//  linked into ZenCODE; every file is downloaded on request, checked against
//  its pinned size and SHA-256, and installed under the support directory.
//

import Foundation

/// One downloadable file of the local voice mode, pinned by URL, size and
/// SHA-256 so a corrupted or replaced upstream file is refused.
struct SherpaOnnxAsset: Sendable, Equatable, Hashable {
    enum Kind: Sendable, Equatable, Hashable {
        /// A `.tar.bz2` archive whose single top-level entry is
        /// `directoryName`.
        case archive(directoryName: String)
        /// A single file installed under its own name.
        case file
    }

    let title: String
    let fileName: String
    let url: URL
    let sha256: String
    let byteCount: Int64
    let kind: Kind

    /// Name of the installed directory or file inside the voice directory.
    var installedName: String {
        switch kind {
        case let .archive(directoryName):
            return directoryName
        case .file:
            return fileName
        }
    }
}

/// A Piper voice that reads answers aloud.
struct SherpaOnnxVoice: Sendable, Equatable, Hashable {
    static let archivePrefix = "vits-piper-"
    static let archiveSuffix = ".tar.bz2"
    static let qualities: Set<String> = ["x_low", "low", "medium", "high"]

    let asset: SherpaOnnxAsset
    /// Piper locale, e.g. `it_IT`.
    let locale: String
    /// Speaker name, e.g. `paola`.
    let speaker: String
    /// Piper quality tier, when the archive name carries one.
    let quality: String?

    /// Stable identifier: the installed directory name.
    var id: String {
        asset.installedName
    }

    /// Lowercased ISO language code, e.g. `it`.
    var languageCode: String {
        locale.split(separator: "_").first.map { $0.lowercased() } ?? locale.lowercased()
    }

    /// `vits-piper-<locale>-<speaker>[-<quality>].tar.bz2`; `nil` for any
    /// other name.
    init?(archive: SherpaOnnxVoiceCatalog.PinnedArchive) {
        let name = archive.archiveName
        guard name.hasPrefix(Self.archivePrefix), name.hasSuffix(Self.archiveSuffix) else {
            return nil
        }
        let directoryName = String(name.dropLast(Self.archiveSuffix.count))
        let components = directoryName.dropFirst(Self.archivePrefix.count)
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count >= 2,
              components[0].contains("_"),
              components.allSatisfy({ !$0.isEmpty }),
              let url = URL(string: SherpaOnnxVoiceCatalog.voiceDownloadBaseURL + name) else {
            return nil
        }
        locale = components[0]
        if components.count >= 3, let last = components.last, Self.qualities.contains(last) {
            quality = last
            speaker = components[1..<(components.count - 1)].joined(separator: "-")
        } else {
            quality = nil
            speaker = components[1...].joined(separator: "-")
        }
        asset = SherpaOnnxAsset(
            title: "voice \(speaker) (\(locale))",
            fileName: name,
            url: url,
            sha256: archive.sha256,
            byteCount: archive.byteCount,
            kind: .archive(directoryName: directoryName)
        )
    }
}

enum SherpaOnnxVoiceCatalog {
    /// A pinned release archive. URLs are derived from the release tag.
    struct PinnedArchive: Sendable, Equatable {
        let archiveName: String
        let sha256: String
        let byteCount: Int64
    }

    static let runtimeVersion = "v1.13.8"
    static let voiceDownloadBaseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/"
    static let modelDownloadBaseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    static let runtimeDownloadBaseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/\(runtimeVersion)/"

    /// Programs used by voice mode, inside the runtime's `bin` directory.
    static let recognizerProgramName = "sherpa-onnx-vad-alsa-offline-asr"
    static let synthesizerProgramName = "sherpa-onnx-offline-tts-play-alsa"
    /// Transcribes an audio file (Telegram voice messages) with the same
    /// voice activity detector and speech recognition model.
    static let fileRecognizerProgramName = "sherpa-onnx-vad-with-offline-asr"

    static let runtimeX64 = archive(
        title: "sherpa-onnx \(runtimeVersion) programs (x86_64)",
        baseURL: runtimeDownloadBaseURL,
        name: "sherpa-onnx-\(runtimeVersion)-linux-x64-shared.tar.bz2",
        sha256: "c0bdb7907d3a74bba1d55d22bf4d9fa75586cf1530614ebe88a27b9118e015c4",
        byteCount: 28_156_791
    )

    static let runtimeARM64 = archive(
        title: "sherpa-onnx \(runtimeVersion) programs (arm64)",
        baseURL: runtimeDownloadBaseURL,
        name: "sherpa-onnx-\(runtimeVersion)-linux-aarch64-shared-cpu.tar.bz2",
        sha256: "4e3734f82bc1379fd91f219f5869c7e9d03b7a4f7561907d8abca4849c51a789",
        byteCount: 28_091_778
    )

    /// Parakeet TDT 0.6B v3 (int8): 25 European languages, punctuation and
    /// casing, language detected automatically.
    static let recognizer = archive(
        title: "speech recognition model (Parakeet TDT 0.6B v3)",
        baseURL: modelDownloadBaseURL,
        name: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
        sha256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
        byteCount: 487_170_055
    )

    static let recognizerEncoderFileName = "encoder.int8.onnx"
    static let recognizerDecoderFileName = "decoder.int8.onnx"
    static let recognizerJoinerFileName = "joiner.int8.onnx"
    static let tokensFileName = "tokens.txt"
    static let voiceDataDirectoryName = "espeak-ng-data"

    static let voiceActivityDetector = SherpaOnnxAsset(
        title: "voice activity detector (Silero VAD)",
        fileName: "silero_vad.onnx",
        url: URL(string: modelDownloadBaseURL + "silero_vad.onnx")!,
        sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
        byteCount: 643_854,
        kind: .file
    )

    /// The runtime archive for the architecture ZenCODE was built for, or
    /// `nil` where no prebuilt programs exist.
    static var runtime: SherpaOnnxAsset? {
        #if arch(x86_64)
        return runtimeX64
        #elseif arch(arm64)
        return runtimeARM64
        #else
        return nil
        #endif
    }

    static let voices: [SherpaOnnxVoice] = pinnedVoiceArchives.compactMap(SherpaOnnxVoice.init(archive:))

    static func voice(id: String) -> SherpaOnnxVoice? {
        voices.first { $0.id == id }
    }

    /// Voices whose locale language matches `languageCode` (`it`, `it-IT`,
    /// `it_IT` all match `it_IT`), ordered by locale, speaker and quality.
    static func voices(forLanguage languageCode: String) -> [SherpaOnnxVoice] {
        let language = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        guard !language.isEmpty else {
            return []
        }
        return voices.filter { $0.languageCode == language }
    }

    /// Everything voice mode needs beside the chosen voice. `nil` runtime
    /// means the architecture has no prebuilt programs.
    static func sharedAssets() -> [SherpaOnnxAsset]? {
        guard let runtime else {
            return nil
        }
        return [runtime, recognizer, voiceActivityDetector]
    }

    private static func archive(
        title: String,
        baseURL: String,
        name: String,
        sha256: String,
        byteCount: Int64
    ) -> SherpaOnnxAsset {
        SherpaOnnxAsset(
            title: title,
            fileName: name,
            url: URL(string: baseURL + name)!,
            sha256: sha256,
            byteCount: byteCount,
            kind: .archive(directoryName: String(name.dropLast(SherpaOnnxVoice.archiveSuffix.count)))
        )
    }
}
