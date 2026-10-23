//
//  TerminalVoiceAudioIO.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation
import Synchronization

/// Mono 24 kHz arithmetic shared by voice capture and playback.
enum TerminalVoicePCM {
    static let sampleRate = 24_000
    static let bytesPerFrame = 2
    static let chunkMilliseconds = 40
    /// 40 ms of PCM16 mono 24 kHz: 960 frames, 1 920 bytes.
    static let chunkByteCount = sampleRate / 1_000 * chunkMilliseconds * bytesPerFrame

    static func milliseconds(forByteCount byteCount: Int) -> Int {
        max(0, byteCount) / (sampleRate / 1_000 * bytesPerFrame)
    }

    static func milliseconds(forFrameCount frameCount: Int) -> Int {
        max(0, frameCount) / (sampleRate / 1_000)
    }

    /// Little-endian PCM16 samples as normalised Float32 in -1...1. A trailing
    /// odd byte is ignored.
    static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else {
            return []
        }
        var samples = [Float](repeating: 0, count: frameCount)
        data.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let value = Int16(bitPattern: low | (high << 8))
                samples[index] = Float(value) / 32_768
            }
        }
        return samples
    }

    /// Normalised Float32 samples as little-endian PCM16, clamped to -1...1.
    static func pcm16Data(fromFloatSamples samples: [Float]) -> Data {
        var data = Data(count: samples.count * bytesPerFrame)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let clamped = sample.isFinite ? min(1, max(-1, sample)) : 0
                let value = UInt16(bitPattern: Int16((clamped * 32_767).rounded()))
                raw[index * 2] = UInt8(value & 0xFF)
                raw[index * 2 + 1] = UInt8(value >> 8)
            }
        }
        return data
    }
}

/// Re-slices converted microphone audio into fixed 40 ms chunks.
struct TerminalVoicePCMChunker: Sendable {
    let chunkByteCount: Int
    private var pending = Data()

    init(chunkByteCount: Int = TerminalVoicePCM.chunkByteCount) {
        self.chunkByteCount = max(TerminalVoicePCM.bytesPerFrame, chunkByteCount)
    }

    var pendingByteCount: Int {
        pending.count
    }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= chunkByteCount {
            chunks.append(Data(pending.prefix(chunkByteCount)))
            pending = Data(pending.dropFirst(chunkByteCount))
        }
        return chunks
    }

    mutating func reset() {
        pending = Data()
    }
}

/// Float capture samples to 40 ms PCM16 chunks, safe to call from the audio
/// capture callback.
final class TerminalVoicePCM16ChunkEncoder: Sendable {
    private let chunker = Mutex(TerminalVoicePCMChunker())

    func encode(_ samples: [Float]) -> [Data] {
        let data = TerminalVoicePCM.pcm16Data(fromFloatSamples: samples)
        return chunker.withLock { $0.append(data) }
    }

    func reset() {
        chunker.withLock { $0.reset() }
    }
}

/// Cumulative played milliseconds of the assistant audio item currently being
/// played. Reported back to the realtime session for barge-in truncation.
struct TerminalVoicePlaybackLedger: Sendable {
    private var itemID: String?
    private var playedMilliseconds = 0

    mutating func recordPlayed(itemID: String, milliseconds: Int) -> Int {
        if self.itemID != itemID {
            self.itemID = itemID
            playedMilliseconds = 0
        }
        playedMilliseconds += max(0, milliseconds)
        return playedMilliseconds
    }

    mutating func reset() {
        itemID = nil
        playedMilliseconds = 0
    }
}

enum TerminalVoiceAudioError: LocalizedError, Equatable {
    case unsupportedPlatform
    case noInputDevice
    case unsupportedInputFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice mode requires macOS."
        case .noInputDevice:
            return "No microphone input device is available."
        case .unsupportedInputFormat:
            return "The microphone input format cannot be converted to 24 kHz mono audio."
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation
import CoreAudio

/// Microphone capture and voice playback for terminal voice mode.
///
/// Capture and playback share one `AVAudioEngine` whose I/O nodes run in the
/// system voice-processing mode, so the echo of everything played through the
/// engine is cancelled from the microphone signal and the user can talk over
/// the assistant. When voice processing is unavailable, or the engine cannot
/// start with it on the current output, the device runs without echo
/// cancellation and `start` reports it.
///
/// Captured audio is delivered as mono 24 kHz Float32 samples; playback takes
/// the same format. Public methods are driven serially by one voice
/// controller; the audio callbacks only touch lock-protected state. Audio never
/// touches the disk.
final class TerminalVoiceAudioDevice: @unchecked Sendable {
    static let isSupported = true

    static let sampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(TerminalVoicePCM.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var isCapturePaused = false
    private var playbackGeneration: UInt64 = 0
    private var pendingPlaybackBuffers = 0
    private var isRunning = false
    private var isVoiceProcessingActive = false

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Starts capture and playback. Returns whether echo cancellation is active.
    ///
    /// Voice processing can be enabled and still fail to start with some
    /// output devices; the engine is then started once more without it.
    @discardableResult
    func start(
        capturePaused: Bool,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws -> Bool {
        guard !isRunning else {
            return isVoiceProcessingActive
        }
        isVoiceProcessingActive = enableVoiceProcessing()
        do {
            try startEngine(capturePaused: capturePaused, onSamples: onSamples)
        } catch {
            guard isVoiceProcessingActive else {
                throw error
            }
            engine.stop()
            disableVoiceProcessing()
            isVoiceProcessingActive = false
            try startEngine(capturePaused: capturePaused, onSamples: onSamples)
        }
        player.play()
        if isVoiceProcessingActive {
            engine.inputNode.isVoiceProcessingInputMuted = capturePaused
        }
        isRunning = true
        return isVoiceProcessingActive
    }

    /// Name of the current default output device, e.g. "AirPlay", or `nil`
    /// when it cannot be read.
    var outputDeviceName: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let name = name?.takeRetainedValue() else {
            return nil
        }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    /// Installs the capture tap for the input node's current format and starts
    /// the engine. On failure the tap and the converter are removed again.
    private func startEngine(
        capturePaused: Bool,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TerminalVoiceAudioError.noInputDevice
        }
        guard let converter = Self.makeConverter(from: inputFormat) else {
            throw TerminalVoiceAudioError.unsupportedInputFormat
        }
        lock.withLock {
            self.converter = converter
            self.onSamples = onSamples
            isCapturePaused = capturePaused
        }

        if player.engine == nil {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: Self.sampleFormat)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                self.converter = nil
                self.onSamples = nil
            }
            throw error
        }
    }

    /// Pausing drops captured audio and mutes the voice-processed input; the
    /// engine keeps running so playback is unaffected.
    func setCapturePaused(_ paused: Bool) {
        lock.withLock { isCapturePaused = paused }
        if isRunning, isVoiceProcessingActive {
            engine.inputNode.isVoiceProcessingInputMuted = paused
        }
    }

    /// Schedules mono 24 kHz Float32 samples. `completion` runs once they were
    /// played, unless playback was interrupted first. Returns whether the
    /// samples were scheduled.
    @discardableResult
    func enqueuePlayback(
        _ samples: [Float],
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        guard isRunning,
              !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: Self.sampleFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        let generation = lock.withLock {
            pendingPlaybackBuffers += 1
            return playbackGeneration
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else {
                return
            }
            let isCurrent = self.lock.withLock {
                guard generation == self.playbackGeneration else {
                    return false
                }
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                return true
            }
            if isCurrent {
                completion?()
            }
        }
        if !player.isPlaying {
            player.play()
        }
        return true
    }

    var hasPendingPlayback: Bool {
        lock.withLock { pendingPlaybackBuffers > 0 }
    }

    /// Drops every scheduled buffer. Late completions of dropped buffers are
    /// fenced by the playback generation and never reported.
    func interruptPlayback() {
        lock.withLock {
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
        }
        guard isRunning else {
            return
        }
        player.stop()
        player.play()
    }

    func stop() {
        lock.withLock {
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
            converter = nil
            onSamples = nil
        }
        guard isRunning else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        isRunning = false
    }

    private func enableVoiceProcessing() -> Bool {
        // Connect the main mixer to the output while it still runs at the
        // hardware rate. Created after voice processing is enabled, it is
        // connected at 44.1 kHz instead, and the voice-processing output unit
        // then fails to initialize (-10875) with every output device.
        _ = engine.mainMixerNode
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if !engine.outputNode.isVoiceProcessingEnabled {
                try engine.outputNode.setVoiceProcessingEnabled(true)
            }
            // Keep other applications' audio audible while voice mode runs.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            return engine.inputNode.isVoiceProcessingEnabled
        } catch {
            disableVoiceProcessing()
            return false
        }
    }

    private func disableVoiceProcessing() {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        let state = lock.withLock { (converter, onSamples, isCapturePaused) }
        guard let converter = state.0, let handler = state.1, !state.2 else {
            return
        }
        let samples = Self.monoSamples(from: buffer, converter: converter)
        if !samples.isEmpty {
            handler(samples)
        }
    }

    /// Converts one buffer to mono 24 kHz Float32 samples with a converter
    /// whose output format is `sampleFormat`.
    static func monoSamples(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter
    ) -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
            return []
        }
        let ratio = sampleFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: sampleFormat, frameCapacity: capacity) else {
            return []
        }
        let feed = TerminalVoiceConverterFeed(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        guard status != .error,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// A converter to `sampleFormat` that keeps only the first channel of a
    /// multichannel source.
    static func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: format, to: sampleFormat) else {
            return nil
        }
        if format.channelCount > 1 {
            converter.channelMap = [0]
        }
        return converter
    }
}

/// Supplies one input buffer to `AVAudioConverter`, then reports no data so
/// the converter keeps its resampling state for the next buffer.
final class TerminalVoiceConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
#else
/// Voice mode needs AVFoundation; elsewhere the device never starts.
final class TerminalVoiceAudioDevice: Sendable {
    static let isSupported = false

    static func requestMicrophoneAccess() async -> Bool {
        false
    }

    @discardableResult
    func start(
        capturePaused: Bool,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws -> Bool {
        throw TerminalVoiceAudioError.unsupportedPlatform
    }

    var outputDeviceName: String? {
        nil
    }

    func setCapturePaused(_ paused: Bool) {}

    @discardableResult
    func enqueuePlayback(
        _ samples: [Float],
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        false
    }

    var hasPendingPlayback: Bool {
        false
    }

    func interruptPlayback() {}

    func stop() {}
}
#endif
