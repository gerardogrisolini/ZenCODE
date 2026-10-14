import Foundation
import AVFoundation
import AudioToolbox

/// Converter is owned exclusively by the serialized input tap callback.
private final class CaptureConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncStream<Data>.Continuation
    init?(source: AVAudioFormat, continuation: AsyncStream<Data>.Continuation) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else { return nil }
        self.converter = converter; self.format = format; self.continuation = continuation
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        let count = AVAudioFrameCount(Double(buffer.frameLength) * 24_000 / buffer.format.sampleRate + 32)
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { continuation.finish(); return }
        var supplied = false
        var error: NSError?
        converter.convert(to: result, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let bytes = result.int16ChannelData else { continuation.finish(); return }
        let data = Data(bytes: bytes[0], count: Int(result.frameLength) * 2)
        if !data.isEmpty, case .dropped = continuation.yield(data) { continuation.finish() }
    }
}

@MainActor final class AudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var continuation: AsyncStream<Data>.Continuation?
    private var tapped = false
    private(set) var receipt = PlaybackReceipt()
    var isDrained: Bool { receipt.drained }
    var onDrained: (() -> Void)?
    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }
    func start() throws -> AsyncStream<Data> {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(12))
        continuation = pair.continuation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conversion = CaptureConverter(source: format, continuation: pair.continuation) else { throw VoiceError.invalid("Microfono non disponibile") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in conversion.consume(buffer) }
        tapped = true
        do { try engine.start(); player.play() } catch { stop(); throw error }
        return pair.stream
    }
    func append(_ data: Data, item: String) throws {
        guard data.count % 2 == 0, data.count <= 480_000 else { throw VoiceError.invalid("Audio PCM non valido") }
        let count = data.count / 2
        guard receipt.scheduled - receipt.played + count <= 24_000 * 30 else { throw VoiceError.overflow }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)), let channel = buffer.floatChannelData?[0] else { throw VoiceError.overflow }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let low = UInt16(raw[i * 2]); let high = UInt16(raw[i * 2 + 1]) << 8
                channel[i] = Float(Int16(bitPattern: low | high)) / 32768
            }
        }
        let token = try receipt.append(item: item, frames: count)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.receipt.epoch == token else { return }
                let wasDrained = self.receipt.drained
                self.receipt.completed(frames: count, token: token)
                if !wasDrained && self.receipt.drained { self.onDrained?() }
            }
        }
        if !player.isPlaying { player.play() }
    }
    func interrupt() -> (String, Int)? {
        // dataPlayedBack (not dataConsumed/rendered) is our conservative acoustic boundary.
        // A partially played final chunk is deliberately excluded, never counted as heard.
        let result = receipt.interrupt()
        player.stop()
        if engine.isRunning { player.play() }
        return result
    }
    func stop() {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        continuation?.finish(); continuation = nil
        _ = interrupt(); player.stop(); engine.stop()
    }
}
