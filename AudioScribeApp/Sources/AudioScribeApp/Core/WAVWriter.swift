import Foundation
import AVFoundation

final class WAVWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let filePath: URL
    private var dataSize: UInt32 = 0
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16
    private let lock = NSLock()

    init(outputPath: URL, sampleRate: UInt32 = 48000, channels: UInt16 = 2, bitsPerSample: UInt16 = 16) throws {
        self.filePath = outputPath
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputPath)

        try writeHeader()
    }

    private func writeHeader() throws {
        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // Placeholder for file size
        header.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size (16 for PCM)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat (1 = PCM)
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })

        let blockAlign = channels * bitsPerSample / 8
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // Placeholder for data size

        try fileHandle.write(contentsOf: header)
    }

    func appendSamples(_ samples: Data) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileHandle.write(contentsOf: samples)
            dataSize += UInt32(samples.count)
        } catch {
            print("Error writing samples: \(error)")
        }
    }

    func appendSamples(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var int16Data = Data(capacity: frameCount * channelCount * 2)

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let sample = floatData[channel][frame]
                let clampedSample = max(-1.0, min(1.0, sample))
                let int16Sample = Int16(clampedSample * Float(Int16.max))
                withUnsafeBytes(of: int16Sample.littleEndian) { int16Data.append(contentsOf: $0) }
            }
        }

        appendSamples(int16Data)
    }

    func finalize() throws {
        lock.lock()
        defer { lock.unlock() }

        // Update file size in RIFF header (offset 4)
        let fileSize = dataSize + 36
        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })

        // Update data size (offset 40)
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        try fileHandle.close()
    }
}
