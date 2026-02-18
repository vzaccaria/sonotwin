import AVFoundation

final class AudioMixer: @unchecked Sendable {
    private let writer: WAVWriter
    private let mixRatio: Float
    private let lock = NSLock()

    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    private let channels: Int
    private let bufferThreshold: Int

    init(writer: WAVWriter, channels: Int = 2, mixRatio: Float = 0.5) {
        self.writer = writer
        self.channels = channels
        self.mixRatio = mixRatio
        // Flush when we have at least 1024 frames of both
        self.bufferThreshold = 1024 * channels
    }

    func addSystemAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        appendToBuffer(&systemBuffer, from: buffer)
        flushIfReady()
    }

    func addMicAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        appendToBuffer(&micBuffer, from: buffer)
        flushIfReady()
    }

    func addAudioDirect(_ buffer: AVAudioPCMBuffer) {
        writer.appendSamples(buffer)
    }

    private func appendToBuffer(_ targetBuffer: inout [Float], from pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }

        let frameCount = Int(pcmBuffer.frameLength)
        let bufferChannels = Int(pcmBuffer.format.channelCount)

        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let srcChannel = min(channel, bufferChannels - 1)
                targetBuffer.append(channelData[srcChannel][frame])
            }
        }
    }

    private func flushIfReady() {
        let samplesToMix = min(systemBuffer.count, micBuffer.count)
        guard samplesToMix >= bufferThreshold else { return }

        var mixed = Data(capacity: samplesToMix * 2)

        for i in 0..<samplesToMix {
            let systemSample = systemBuffer[i]
            let micSample = micBuffer[i]

            // Mix with equal ratio and clamp
            let mixedSample = (systemSample * mixRatio) + (micSample * (1.0 - mixRatio))
            let clampedSample = max(-1.0, min(1.0, mixedSample))
            let int16Sample = Int16(clampedSample * Float(Int16.max))

            withUnsafeBytes(of: int16Sample.littleEndian) { mixed.append(contentsOf: $0) }
        }

        writer.appendSamples(mixed)

        systemBuffer.removeFirst(samplesToMix)
        micBuffer.removeFirst(samplesToMix)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }

        // Flush remaining samples, padding shorter buffer with silence
        let maxCount = max(systemBuffer.count, micBuffer.count)
        guard maxCount > 0 else { return }

        var mixed = Data(capacity: maxCount * 2)

        for i in 0..<maxCount {
            let systemSample = i < systemBuffer.count ? systemBuffer[i] : 0.0
            let micSample = i < micBuffer.count ? micBuffer[i] : 0.0

            let mixedSample = (systemSample * mixRatio) + (micSample * (1.0 - mixRatio))
            let clampedSample = max(-1.0, min(1.0, mixedSample))
            let int16Sample = Int16(clampedSample * Float(Int16.max))

            withUnsafeBytes(of: int16Sample.littleEndian) { mixed.append(contentsOf: $0) }
        }

        writer.appendSamples(mixed)
        systemBuffer.removeAll()
        micBuffer.removeAll()
    }
}
