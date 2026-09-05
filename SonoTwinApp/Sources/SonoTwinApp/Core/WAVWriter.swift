import Foundation
import AVFoundation

// MARK: - WAVWriter
// Writes audio data to a WAV file.
//
// WAV is a simple, uncompressed audio format:
// - 44-byte header describing the audio format
// - Raw PCM audio data
// - Header fields updated at the end with actual data size
//
// WAV File Structure:
// ┌────────────────────────────────────┐
// │ RIFF Header (12 bytes)             │
// │   "RIFF" + file size + "WAVE"      │
// ├────────────────────────────────────┤
// │ fmt Subchunk (24 bytes)            │
// │   Audio format, channels, rate...  │
// ├────────────────────────────────────┤
// │ data Subchunk Header (8 bytes)     │
// │   "data" + data size               │
// ├────────────────────────────────────┤
// │ Audio Data (variable)              │
// │   Raw PCM samples                  │
// └────────────────────────────────────┘
//
// @unchecked Sendable: File writes are protected by NSLock.

final class WAVWriter: @unchecked Sendable {

    // MARK: - Properties

    private let fileHandle: FileHandle
    private let filePath: URL

    /// Running count of audio bytes written (excludes header).
    private var dataSize: UInt32 = 0

    /// Audio format parameters.
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    /// Thread safety for writes.
    private let lock = NSLock()

    // MARK: - Initialization

    /// Create a WAV file and write the header.
    /// - Parameters:
    ///   - outputPath: Where to create the file
    ///   - sampleRate: Samples per second (e.g., 48000)
    ///   - channels: Number of channels (1 = mono, 2 = stereo)
    ///   - bitsPerSample: Bits per sample (typically 16)
    init(
        outputPath: URL,
        sampleRate: UInt32 = 48000,
        channels: UInt16 = 2,
        bitsPerSample: UInt16 = 16
    ) throws {
        self.filePath = outputPath
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputPath)
        try writeHeader()
    }

    // MARK: - Header Writing

    /// Write the WAV header with placeholder size values.
    /// finalize() updates these with actual sizes.
    private func writeHeader() throws {
        var header = Data()

        // MARK: RIFF Header
        // "RIFF" magic bytes identify this as a RIFF file.
        header.append(contentsOf: "RIFF".utf8)
        // File size minus 8 (placeholder, updated in finalize).
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        // "WAVE" identifies this RIFF file as audio.
        header.append(contentsOf: "WAVE".utf8)

        // MARK: fmt Subchunk
        // Describes the audio format.
        header.append(contentsOf: "fmt ".utf8)
        // Subchunk size (16 bytes for PCM).
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        // Audio format (1 = PCM, uncompressed).
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        // Number of channels.
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        // Sample rate.
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })

        // Byte rate = sampleRate * channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })

        // Block align = channels * bitsPerSample / 8
        // This is the size of one "frame" (one sample from each channel).
        let blockAlign = channels * bitsPerSample / 8
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })

        // Bits per sample.
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // MARK: data Subchunk
        header.append(contentsOf: "data".utf8)
        // Data size (placeholder, updated in finalize).
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })

        try fileHandle.write(contentsOf: header)
    }

    // MARK: - Writing Audio Data

    /// Append raw audio bytes to the file.
    func appendSamples(_ samples: Data) {
        do {
            try appendSamplesThrowing(samples)
        } catch {
            print("Error writing samples: \(error)")
        }
    }

    func appendSamplesThrowing(_ samples: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        try fileHandle.write(contentsOf: samples)
        dataSize += UInt32(samples.count)
    }

    /// Convert a non-interleaved Float32 buffer to interleaved PCM16.
    static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var int16Data = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)

        int16Data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sample = floatData[channel][frame]
                    let clampedSample = max(-1.0, min(1.0, sample))
                    output[frame * channelCount + channel] =
                        Int16(clampedSample * Float(Int16.max)).littleEndian
                }
            }
        }

        return int16Data
    }

    /// Convert AVAudioPCMBuffer to PCM16 and append.
    func appendSamples(_ buffer: AVAudioPCMBuffer) {
        guard let samples = Self.pcm16Data(from: buffer) else { return }
        appendSamples(samples)
    }

    // MARK: - Finalization

    /// Update header with actual sizes and close the file.
    /// MUST be called when recording ends!
    func finalize() throws {
        lock.lock()
        defer { lock.unlock() }

        // MARK: Update RIFF Size
        // Location: offset 4, value: dataSize + 36
        // (36 = rest of header after this field)
        let fileSize = dataSize + 36
        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })

        // MARK: Update Data Size
        // Location: offset 40, value: dataSize
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        try fileHandle.synchronize()

        // Close the file.
        try fileHandle.close()
    }
}
