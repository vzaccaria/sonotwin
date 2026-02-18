import AVFoundation

// MARK: - AudioMixer
// Combines two audio streams (system audio + microphone) into one.
//
// The challenge: Audio from different sources arrives asynchronously.
// System audio might deliver 1024 samples, then mic delivers 512, etc.
// We need to buffer and align them before mixing.
//
// Strategy:
// 1. Buffer incoming samples from each source
// 2. When both buffers have enough data, mix and write
// 3. On flush(), mix whatever remains (padding with silence if needed)
//
// @unchecked Sendable: Audio callbacks come from different threads.
// We use NSLock for thread-safe buffer access.

final class AudioMixer: @unchecked Sendable {

    // MARK: - Properties

    /// The WAV writer to output mixed audio.
    private let writer: WAVWriter

    /// Mix ratio: 0.5 = equal parts system and mic.
    /// Higher = more system audio, lower = more microphone.
    private let mixRatio: Float

    /// Thread synchronization.
    private let lock = NSLock()

    /// Buffers for incoming audio (interleaved format: [L,R,L,R,...]).
    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []

    /// Number of audio channels (typically 2 for stereo).
    private let channels: Int

    /// Minimum samples to accumulate before mixing.
    /// This ensures we have enough data to mix efficiently.
    private let bufferThreshold: Int

    // MARK: - Initialization

    init(writer: WAVWriter, channels: Int = 2, mixRatio: Float = 0.5) {
        self.writer = writer
        self.channels = channels
        self.mixRatio = mixRatio
        // Threshold = 1024 frames * number of channels.
        // A "frame" is one sample per channel.
        self.bufferThreshold = 1024 * channels
    }

    // MARK: - Adding Audio

    /// Add system audio samples to the buffer.
    /// Called from SystemAudioCapture's callback thread.
    func addSystemAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        appendToBuffer(&systemBuffer, from: buffer)
        flushIfReady()
    }

    /// Add microphone audio samples to the buffer.
    /// Called from MicrophoneCapture's callback thread.
    func addMicAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        appendToBuffer(&micBuffer, from: buffer)
        flushIfReady()
    }

    /// Write audio directly without mixing (for single-source mode).
    func addAudioDirect(_ buffer: AVAudioPCMBuffer) {
        writer.appendSamples(buffer)
    }

    // MARK: - Private Methods

    /// Convert AVAudioPCMBuffer to flat Float array and append to buffer.
    /// AVAudioPCMBuffer stores channels separately; we interleave them.
    private func appendToBuffer(_ targetBuffer: inout [Float], from pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }

        let frameCount = Int(pcmBuffer.frameLength)
        let bufferChannels = Int(pcmBuffer.format.channelCount)

        // Convert from non-interleaved to interleaved format.
        // Non-interleaved: [L0,L1,L2,...], [R0,R1,R2,...]
        // Interleaved:     [L0,R0,L1,R1,L2,R2,...]
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                // If source has fewer channels, duplicate the last channel.
                let srcChannel = min(channel, bufferChannels - 1)
                targetBuffer.append(channelData[srcChannel][frame])
            }
        }
    }

    /// Mix and write if we have enough samples from both sources.
    private func flushIfReady() {
        // Only mix the minimum available from both buffers.
        let samplesToMix = min(systemBuffer.count, micBuffer.count)
        guard samplesToMix >= bufferThreshold else { return }

        // MARK: Mix Samples
        // Allocate output buffer (16-bit = 2 bytes per sample).
        var mixed = Data(capacity: samplesToMix * 2)

        for i in 0..<samplesToMix {
            let systemSample = systemBuffer[i]
            let micSample = micBuffer[i]

            // Weighted sum of both sources.
            // mixRatio controls the balance (0.5 = equal).
            let mixedSample = (systemSample * mixRatio) + (micSample * (1.0 - mixRatio))

            // Clamp to [-1.0, 1.0] to prevent clipping distortion.
            let clampedSample = max(-1.0, min(1.0, mixedSample))

            // Convert float [-1.0, 1.0] to 16-bit integer.
            // Int16.max = 32767, so we scale by that.
            let int16Sample = Int16(clampedSample * Float(Int16.max))

            // Append as little-endian bytes (WAV format requirement).
            withUnsafeBytes(of: int16Sample.littleEndian) { mixed.append(contentsOf: $0) }
        }

        // Write to file.
        writer.appendSamples(mixed)

        // Remove the mixed samples from buffers.
        systemBuffer.removeFirst(samplesToMix)
        micBuffer.removeFirst(samplesToMix)
    }

    // MARK: - Final Flush

    /// Flush remaining buffered samples (called when recording stops).
    /// Pads the shorter buffer with silence so we don't lose data.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        // Mix whatever remains, padding the shorter buffer with silence.
        let maxCount = max(systemBuffer.count, micBuffer.count)
        guard maxCount > 0 else { return }

        var mixed = Data(capacity: maxCount * 2)

        for i in 0..<maxCount {
            // Use 0.0 (silence) if one buffer is shorter.
            let systemSample = i < systemBuffer.count ? systemBuffer[i] : 0.0
            let micSample = i < micBuffer.count ? micBuffer[i] : 0.0

            let mixedSample = (systemSample * mixRatio) + (micSample * (1.0 - mixRatio))
            let clampedSample = max(-1.0, min(1.0, mixedSample))
            let int16Sample = Int16(clampedSample * Float(Int16.max))

            withUnsafeBytes(of: int16Sample.littleEndian) { mixed.append(contentsOf: $0) }
        }

        writer.appendSamples(mixed)

        // Clear buffers.
        systemBuffer.removeAll()
        micBuffer.removeAll()
    }
}
