//
//  VoiceAudioIO.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation

/// Mono audio format shared by voice capture and playback.
enum VoicePCM {
    static let sampleRate = 24_000
}

enum VoiceAudioError: LocalizedError, Equatable {
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

/// Microphone capture and voice playback for voice mode.
///
/// Capture and playback share one `AVAudioEngine` whose I/O nodes run in the
/// system voice-processing mode, so the echo of everything played through the
/// engine is cancelled from the microphone signal and the user can talk over
/// the assistant. When voice processing is unavailable, or the engine cannot
/// start with it on the current output, the device runs without echo
/// cancellation and `start` reports it.
///
/// The engine stops itself when the audio hardware changes, e.g. when
/// headphones are connected or disconnected; while the device runs, `start`'s
/// `onConfigurationChange` reports it, so the controller can start the device
/// again. The report can also come with the engine still running, e.g. shortly
/// after voice processing was enabled: `hasStoppedItself` tells them apart.
/// Playback is never scheduled on a stopped engine.
///
/// Captured audio is delivered as mono 24 kHz Float32 samples; playback takes
/// the same format. Public methods are driven serially by one voice
/// controller, except `enqueuePlayback`, which the synthesizer calls from its
/// own queue: starting, stopping and scheduling playback are serialized by
/// `engineLock`, so playback never reaches an engine being stopped. The audio
/// callbacks only touch the state protected by `lock`. Audio never touches the
/// disk.
final class VoiceAudioDevice: @unchecked Sendable {
    static let isSupported = true

    static let sampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(VoicePCM.sampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Protects the state the audio callbacks read. Never held while calling
    /// into the engine, whose stop may wait for those callbacks.
    private let lock = NSLock()
    /// Serializes `start`, `stop`, `enqueuePlayback` and `interruptPlayback`.
    /// Never taken by the audio callbacks.
    private let engineLock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var playbackGeneration: UInt64 = 0
    private var isRunning = false
    private var isVoiceProcessingActive = false
    /// Observes the engine's configuration changes while the device runs.
    private var configurationObserver: (any NSObjectProtocol)?

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
    ///
    /// Until `stop()`, `onConfigurationChange` runs, on an internal queue,
    /// whenever the audio hardware changed, and when the engine is found
    /// stopped right after starting. If the engine stopped itself
    /// (`hasStoppedItself`), the device must be stopped and started again,
    /// which installs the capture tap for the new input format.
    @discardableResult
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws -> Bool {
        engineLock.lock()
        defer {
            engineLock.unlock()
        }
        guard !isRunning else {
            return isVoiceProcessingActive
        }
        isVoiceProcessingActive = enableVoiceProcessing()
        do {
            try startEngine(onSamples: onSamples)
        } catch {
            guard isVoiceProcessingActive else {
                throw error
            }
            engine.stop()
            disableVoiceProcessing()
            isVoiceProcessingActive = false
            try startEngine(onSamples: onSamples)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onConfigurationChange()
        }
        isRunning = true
        guard engine.isRunning else {
            // The engine stopped itself while starting, possibly before the
            // change could be observed: report it, so the device starts again.
            onConfigurationChange()
            return isVoiceProcessingActive
        }
        player.play()
        return isVoiceProcessingActive
    }

    /// Whether the device was started and its engine is no longer running:
    /// the engine stopped itself, e.g. after the audio hardware changed.
    /// `false` before `start`, after `stop` and while the engine runs.
    var hasStoppedItself: Bool {
        engineLock.lock()
        defer {
            engineLock.unlock()
        }
        return isRunning && !engine.isRunning
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
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceAudioError.noInputDevice
        }
        guard let converter = Self.makeConverter(from: inputFormat) else {
            throw VoiceAudioError.unsupportedInputFormat
        }
        lock.withLock {
            self.converter = converter
            self.onSamples = onSamples
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

    /// Schedules mono 24 kHz Float32 samples. `completion` runs once they were
    /// played, unless playback was interrupted first. Returns whether the
    /// samples were scheduled: never while the device or its engine is
    /// stopped, e.g. after the audio hardware changed.
    @discardableResult
    func enqueuePlayback(
        _ samples: [Float],
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        engineLock.lock()
        defer {
            engineLock.unlock()
        }
        guard isRunning,
              engine.isRunning,
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
        let generation = lock.withLock { playbackGeneration }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else {
                return
            }
            let isCurrent = self.lock.withLock {
                generation == self.playbackGeneration
            }
            if isCurrent {
                completion?()
            }
        }
        // Playing on a stopped engine raises an exception: the engine may
        // have stopped itself meanwhile.
        if !player.isPlaying, engine.isRunning {
            player.play()
        }
        return true
    }

    /// Drops every scheduled buffer. Late completions of dropped buffers are
    /// fenced by the playback generation and never reported. On a stopped
    /// engine only the generation advances: `stop()` drops the buffers.
    func interruptPlayback() {
        lock.withLock {
            playbackGeneration &+= 1
        }
        engineLock.lock()
        defer {
            engineLock.unlock()
        }
        guard isRunning, engine.isRunning else {
            return
        }
        player.stop()
        if engine.isRunning {
            player.play()
        }
    }

    /// Stops capture and playback and the observation of configuration
    /// changes; scheduled buffers are dropped.
    func stop() {
        lock.withLock {
            playbackGeneration &+= 1
            converter = nil
            onSamples = nil
        }
        engineLock.lock()
        defer {
            engineLock.unlock()
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
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
        let state = lock.withLock { (converter, onSamples) }
        guard let converter = state.0, let handler = state.1 else {
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
        let feed = VoiceConverterFeed(buffer)
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
final class VoiceConverterFeed: @unchecked Sendable {
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
final class VoiceAudioDevice: Sendable {
    static let isSupported = false

    static func requestMicrophoneAccess() async -> Bool {
        false
    }

    @discardableResult
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws -> Bool {
        throw VoiceAudioError.unsupportedPlatform
    }

    var hasStoppedItself: Bool {
        false
    }

    var outputDeviceName: String? {
        nil
    }

    @discardableResult
    func enqueuePlayback(
        _ samples: [Float],
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        false
    }

    func interruptPlayback() {}

    func stop() {}
}
#endif
