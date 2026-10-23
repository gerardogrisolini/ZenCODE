//
//  SherpaOnnxVoiceAssetsTests.swift
//  ZenCODECoreTests
//

import Crypto
import Foundation
import Testing
@testable import ZenCODECore

@Suite("Sherpa-onnx voice assets")
struct SherpaOnnxVoiceAssetsTests {
    // MARK: - Catalog

    @Test
    func everyPinnedAssetHasAnHTTPSReleaseURLSizeAndChecksum() {
        var assets = SherpaOnnxVoiceCatalog.voices.map(\.asset)
        assets += [
            SherpaOnnxVoiceCatalog.runtimeX64,
            SherpaOnnxVoiceCatalog.runtimeARM64,
            SherpaOnnxVoiceCatalog.recognizer,
            SherpaOnnxVoiceCatalog.voiceActivityDetector
        ]
        #expect(SherpaOnnxVoiceCatalog.voices.count == SherpaOnnxVoiceCatalog.pinnedVoiceArchives.count)
        #expect(Set(assets.map(\.installedName)).count == assets.count)
        for asset in assets {
            #expect(asset.url.absoluteString.hasPrefix("https://github.com/k2-fsa/sherpa-onnx/releases/download/"))
            #expect(asset.url.lastPathComponent == asset.fileName)
            #expect(asset.byteCount > 0)
            #expect(asset.sha256.count == 64)
            #expect(asset.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test
    func voicesCoverTheRecognizerLanguagesThatHaveAPiperVoice() {
        let languages = Set(SherpaOnnxVoiceCatalog.voices.map(\.languageCode))
        #expect(languages == [
            "cs", "da", "de", "el", "en", "es", "fi", "fr", "hu", "it",
            "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"
        ])
    }

    @Test
    func voicesAreFilteredByLanguageInAnySpelling() {
        let italian = SherpaOnnxVoiceCatalog.voices(forLanguage: "it").map(\.speaker)
        #expect(italian == ["dii", "miro", "paola", "riccardo"])
        #expect(SherpaOnnxVoiceCatalog.voices(forLanguage: "IT-it").map(\.speaker) == italian)
        #expect(SherpaOnnxVoiceCatalog.voices(forLanguage: "it_IT").map(\.speaker) == italian)
        #expect(SherpaOnnxVoiceCatalog.voices(forLanguage: "xx").isEmpty)
        #expect(SherpaOnnxVoiceCatalog.voices(forLanguage: " ").isEmpty)
    }

    @Test
    func piperArchiveNamesParseIntoLocaleSpeakerAndQuality() throws {
        let paola = try #require(SherpaOnnxVoice(archive: .init(
            archiveName: "vits-piper-it_IT-paola-medium.tar.bz2",
            sha256: String(repeating: "a", count: 64),
            byteCount: 1
        )))
        #expect(paola.locale == "it_IT")
        #expect(paola.speaker == "paola")
        #expect(paola.quality == "medium")
        #expect(paola.languageCode == "it")
        #expect(paola.id == "vits-piper-it_IT-paola-medium")
        #expect(paola.asset.kind == .archive(directoryName: "vits-piper-it_IT-paola-medium"))
        #expect(paola.asset.url.absoluteString == "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-it_IT-paola-medium.tar.bz2")

        let multipart = try #require(SherpaOnnxVoice(archive: .init(
            archiveName: "vits-piper-fr_FR-tjiho-model1.tar.bz2",
            sha256: String(repeating: "a", count: 64),
            byteCount: 1
        )))
        #expect(multipart.speaker == "tjiho-model1")
        #expect(multipart.quality == nil)

        for invalid in ["vits-piper-it_IT.tar.bz2", "vits-it_IT-paola-medium.tar.bz2", "vits-piper-itIT-paola.tar.bz2", "vits-piper-it_IT-paola-medium.zip"] {
            #expect(SherpaOnnxVoice(archive: .init(archiveName: invalid, sha256: "", byteCount: 1)) == nil)
        }
    }

    @Test
    func sharedAssetsFollowTheBuildArchitecture() throws {
        #if arch(x86_64) || arch(arm64)
        let shared = try #require(SherpaOnnxVoiceCatalog.sharedAssets())
        #if arch(x86_64)
        #expect(shared.first == SherpaOnnxVoiceCatalog.runtimeX64)
        #else
        #expect(shared.first == SherpaOnnxVoiceCatalog.runtimeARM64)
        #endif
        #expect(shared.dropFirst() == [SherpaOnnxVoiceCatalog.recognizer, SherpaOnnxVoiceCatalog.voiceActivityDetector])
        #endif
    }

    // MARK: - Installation layout

    @Test
    func completeInstallationResolvesRuntimePathsAndAnythingMissingIsReported() throws {
        let installation = try makeInstallation()
        #expect(installation.runtimePaths() == .failure(.notInstalled))
        #expect(!installation.hasInstalledFiles)

        let voice = try #require(SherpaOnnxVoiceCatalog.voices(forLanguage: "it").first)
        try createInstalledLayout(installation: installation, voice: voice)
        let paths = try installation.runtimePaths().get()
        let runtimeBin = installation.installedURL(for: try #require(SherpaOnnxVoiceCatalog.runtime))
            .appendingPathComponent("bin")
        #expect(paths.recognizerProgram == runtimeBin.appendingPathComponent("sherpa-onnx-vad-alsa-offline-asr"))
        #expect(paths.synthesizerProgram == runtimeBin.appendingPathComponent("sherpa-onnx-offline-tts-play-alsa"))
        #expect(paths.voice == voice)
        #expect(paths.voiceModel.lastPathComponent == "voice.onnx")
        #expect(installation.missingAssets(for: voice) == [])
        #expect(installation.hasInstalledFiles)

        // A voice directory with two models is not a usable voice.
        try Data().write(to: installation.installedURL(for: voice.asset).appendingPathComponent("second.onnx"))
        #expect(installation.runtimePaths() == .failure(.unexpectedLayout(voice.asset.fileName)))
    }

    @Test
    func keepingOneVoiceRemovesTheOthers() throws {
        let installation = try makeInstallation()
        let voices = SherpaOnnxVoiceCatalog.voices(forLanguage: "it")
        for voice in voices.prefix(2) {
            try FileManager.default.createDirectory(
                at: installation.installedURL(for: voice.asset),
                withIntermediateDirectories: true
            )
        }
        #expect(installation.installedVoices() == Array(voices.prefix(2)))

        try SherpaOnnxVoiceInstaller(installation: installation, downloader: FakeDownloader([:]))
            .removeVoices(except: voices[1])
        #expect(installation.installedVoices() == [voices[1]])
    }

    // MARK: - Installer

    @Test
    func aVerifiedFileIsInstalledAndStagingIsRemoved() async throws {
        let installation = try makeInstallation()
        let payload = Data("silero".utf8)
        let asset = fileAsset(named: "vad.onnx", payload: payload)
        let installer = SherpaOnnxVoiceInstaller(
            installation: installation,
            downloader: FakeDownloader([asset.url: payload])
        )
        let steps = StepRecorder()
        try await installer.install(asset) { steps.record($0) }

        #expect(try Data(contentsOf: installation.installedURL(for: asset)) == payload)
        #expect(!FileManager.default.fileExists(atPath: installation.stagingDirectoryURL.path))
        #expect(steps.values.last == .installed(asset))
        #expect(steps.values.contains(.downloading(asset, receivedBytes: Int64(payload.count))))
    }

    @Test
    func aChecksumOrSizeMismatchInstallsNothing() async throws {
        let installation = try makeInstallation()
        let asset = fileAsset(named: "vad.onnx", payload: Data("expected".utf8))

        let tampered = SherpaOnnxVoiceInstaller(
            installation: installation,
            downloader: FakeDownloader([asset.url: Data("tampered".utf8)])
        )
        await #expect(throws: SherpaOnnxVoiceInstallError.checksumMismatch(fileName: "vad.onnx")) {
            try await tampered.install(asset)
        }

        let truncated = SherpaOnnxVoiceInstaller(
            installation: installation,
            downloader: FakeDownloader([asset.url: Data("short".utf8)])
        )
        await #expect(throws: SherpaOnnxVoiceInstallError.sizeMismatch(fileName: "vad.onnx", expected: 8, actual: 5)) {
            try await truncated.install(asset)
        }

        #expect(!installation.isInstalled(asset))
        #expect(!FileManager.default.fileExists(atPath: installation.stagingDirectoryURL.path))
    }

    @Test(.enabled(if: SherpaOnnxVoiceAssetsTests.canUnpack))
    func anArchiveIsUnpackedAndReplacesTheInstalledCopy() async throws {
        let installation = try makeInstallation()
        let first = try makeArchive(directoryName: "vits-piper-zz_ZZ-test-low", files: ["voice.onnx": "one"])
        let asset = archiveAsset(directoryName: "vits-piper-zz_ZZ-test-low", payload: first)
        try await SherpaOnnxVoiceInstaller(
            installation: installation,
            downloader: FakeDownloader([asset.url: first])
        ).install(asset)
        let installedModel = installation.installedURL(for: asset).appendingPathComponent("voice.onnx")
        #expect(try String(contentsOf: installedModel, encoding: .utf8) == "one")

        let second = try makeArchive(directoryName: "vits-piper-zz_ZZ-test-low", files: ["voice.onnx": "two"])
        let replacement = archiveAsset(directoryName: "vits-piper-zz_ZZ-test-low", payload: second)
        try await SherpaOnnxVoiceInstaller(
            installation: installation,
            downloader: FakeDownloader([replacement.url: second])
        ).install(replacement)
        #expect(try String(contentsOf: installedModel, encoding: .utf8) == "two")
    }

    @Test(.enabled(if: SherpaOnnxVoiceAssetsTests.canUnpack))
    func anArchiveWithAnotherTopLevelDirectoryIsRefused() async throws {
        let installation = try makeInstallation()
        let payload = try makeArchive(directoryName: "something-else", files: ["voice.onnx": "x"])
        let asset = archiveAsset(directoryName: "vits-piper-zz_ZZ-test-low", payload: payload)
        await #expect(throws: SherpaOnnxVoiceInstallError.unexpectedLayout(asset.fileName)) {
            try await SherpaOnnxVoiceInstaller(
                installation: installation,
                downloader: FakeDownloader([asset.url: payload])
            ).install(asset)
        }
        #expect(!installation.isInstalled(asset))
    }

    @Test
    func removeAllDeletesTheVoiceDirectory() throws {
        let installation = try makeInstallation()
        try FileManager.default.createDirectory(at: installation.directoryURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: installation.directoryURL.appendingPathComponent("silero_vad.onnx"))
        let installer = SherpaOnnxVoiceInstaller(installation: installation, downloader: FakeDownloader([:]))
        try installer.removeAll()
        #expect(!FileManager.default.fileExists(atPath: installation.directoryURL.path))
        try installer.removeAll()
    }

    /// Opt-in network check of the real HTTPS downloader against the pinned
    /// 0.6 MB voice activity model: `ZENCODE_RUN_LIVE_VOICE_DOWNLOAD=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZENCODE_RUN_LIVE_VOICE_DOWNLOAD"] == "1"))
    func liveDownloadOfThePinnedVoiceActivityModelVerifies() async throws {
        let installation = try makeInstallation()
        let asset = SherpaOnnxVoiceCatalog.voiceActivityDetector
        try await SherpaOnnxVoiceInstaller(installation: installation).install(asset)
        let attributes = try FileManager.default.attributesOfItem(atPath: installation.installedURL(for: asset).path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == asset.byteCount)
    }

    /// Opt-in end-to-end download of everything voice mode needs for an
    /// Italian voice (about 580 MB): `ZENCODE_RUN_LIVE_VOICE_INSTALL=1`. Set
    /// `ZENCODE_LIVE_VOICE_DIRECTORY` to keep the files for manual checks.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["ZENCODE_RUN_LIVE_VOICE_INSTALL"] == "1"),
        .timeLimit(.minutes(30))
    )
    func liveInstallOfAnItalianVoiceResolvesTheRuntime() async throws {
        let installation = try ProcessInfo.processInfo.environment["ZENCODE_LIVE_VOICE_DIRECTORY"]
            .map { SherpaOnnxVoiceInstallation(directoryURL: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? makeInstallation()
        let voice = try #require(SherpaOnnxVoiceCatalog.voices(forLanguage: "it").first { $0.speaker == "paola" })
        try await SherpaOnnxVoiceInstaller(installation: installation).install(voice: voice)
        let paths = try installation.runtimePaths().get()
        #expect(paths.voice == voice)
        #expect(installation.missingAssets(for: voice) == [])
    }

    // MARK: - Support

    private func makeInstallation() throws -> SherpaOnnxVoiceInstallation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-voice-\(UUID().uuidString)", isDirectory: true)
        return SherpaOnnxVoiceInstallation(directoryURL: root.appendingPathComponent("voice", isDirectory: true))
    }

    /// `tar` and `bzip2` are needed to build and unpack test archives.
    static var canUnpack: Bool {
        (try? SherpaOnnxVoiceInstaller.checkUnpackingTools()) != nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileAsset(named name: String, payload: Data) -> SherpaOnnxAsset {
        SherpaOnnxAsset(
            title: name,
            fileName: name,
            url: URL(string: "https://example.invalid/\(UUID().uuidString)/\(name)")!,
            sha256: sha256(payload),
            byteCount: Int64(payload.count),
            kind: .file
        )
    }

    private func archiveAsset(directoryName: String, payload: Data) -> SherpaOnnxAsset {
        let name = directoryName + ".tar.bz2"
        return SherpaOnnxAsset(
            title: directoryName,
            fileName: name,
            url: URL(string: "https://example.invalid/\(UUID().uuidString)/\(name)")!,
            sha256: sha256(payload),
            byteCount: Int64(payload.count),
            kind: .archive(directoryName: directoryName)
        )
    }

    private func makeArchive(directoryName: String, files: [String: String]) throws -> Data {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-voice-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        let directory = work.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        let archive = work.appendingPathComponent("archive.tar.bz2")
        _ = try SupportDirectoryArchive.runTar(
            ["-cjf", archive.path, "-C", work.path, directoryName],
            fileManager: fileManager
        )
        return try Data(contentsOf: archive)
    }

    private func createInstalledLayout(
        installation: SherpaOnnxVoiceInstallation,
        voice: SherpaOnnxVoice
    ) throws {
        let fileManager = FileManager.default
        let runtime = try #require(SherpaOnnxVoiceCatalog.runtime)
        let bin = installation.installedURL(for: runtime).appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        for program in [SherpaOnnxVoiceCatalog.recognizerProgramName, SherpaOnnxVoiceCatalog.synthesizerProgramName] {
            let url = bin.appendingPathComponent(program)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let recognizer = installation.installedURL(for: SherpaOnnxVoiceCatalog.recognizer)
        try fileManager.createDirectory(at: recognizer, withIntermediateDirectories: true)
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
            try Data().write(to: recognizer.appendingPathComponent(name))
        }
        try Data().write(to: installation.installedURL(for: SherpaOnnxVoiceCatalog.voiceActivityDetector))
        let voiceDirectory = installation.installedURL(for: voice.asset)
        try fileManager.createDirectory(
            at: voiceDirectory.appendingPathComponent("espeak-ng-data", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: voiceDirectory.appendingPathComponent("voice.onnx"))
        try Data().write(to: voiceDirectory.appendingPathComponent("tokens.txt"))
    }
}

/// Serves in-memory payloads in small chunks.
private struct FakeDownloader: SherpaOnnxAssetDownloading {
    let payloads: [URL: Data]

    init(_ payloads: [URL: Data]) {
        self.payloads = payloads
    }

    func download(
        _ url: URL,
        maximumByteCount: Int64,
        onChunk: (Data) throws -> Void
    ) async throws {
        guard let payload = payloads[url] else {
            throw SherpaOnnxVoiceInstallError.httpStatus(404)
        }
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 3, payload.count)
            try onChunk(payload.subdata(in: offset..<end))
            offset = end
        }
    }
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SherpaOnnxVoiceInstaller.Step] = []

    var values: [SherpaOnnxVoiceInstaller.Step] {
        lock.withLock { recorded }
    }

    func record(_ step: SherpaOnnxVoiceInstaller.Step) {
        lock.withLock { recorded.append(step) }
    }
}
