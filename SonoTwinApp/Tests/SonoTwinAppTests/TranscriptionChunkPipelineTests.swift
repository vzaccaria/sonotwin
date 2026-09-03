import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct TranscriptionChunkPipelineTests {
    @Test
    func producesTimestampedAtomicOverlappingChunks() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let chunksDirectory = root.appendingPathComponent("chunks")
        let collector = ChunkCollector()
        let pipeline = try TranscriptionChunkPipeline(
            configuration: .init(
                chunksDirectory: chunksDirectory,
                maxQueuedBytes: 3_000_000
            ),
            onChunkReady: { collector.record($0) }
        )

        #expect(pipeline.append(stereoPCM(seconds: 11)))
        try await pipeline.finish()

        let chunks = collector.chunks
        #expect(chunks.map(\.sequence) == [0, 1, 2])
        #expect(chunks.map(\.startMilliseconds) == [0, 4_000, 9_000])
        #expect(chunks.map(\.endMilliseconds) == [5_000, 10_000, 11_000])
        #expect(
            chunks.map { $0.url.lastPathComponent } == [
                "000000_000000000000_000000005000.wav",
                "000001_000000004000_000000010000.wav",
                "000002_000000009000_000000011000.wav"
            ]
        )
        #expect(collector.readyFilesExisted == [true, true, true])

        let directoryEntries = try FileManager.default.contentsOfDirectory(
            at: chunksDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!directoryEntries.contains { $0.pathExtension == "part" })

        let expectedDurations = [5, 6, 2]
        for (chunk, duration) in zip(chunks, expectedDurations) {
            let wav = try Data(contentsOf: chunk.url)
            #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
            #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
            #expect(littleEndianUInt16(wav, at: 20) == 1)
            #expect(littleEndianUInt16(wav, at: 22) == 1)
            #expect(littleEndianUInt32(wav, at: 24) == 16_000)
            #expect(littleEndianUInt16(wav, at: 34) == 16)
            #expect(littleEndianUInt32(wav, at: 40) == UInt32(duration * 16_000 * 2))
            #expect(littleEndianUInt32(wav, at: 4) == UInt32(wav.count - 8))
        }
    }

    @Test
    func rejectsBacklogWithoutPublishingAChunk() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let failureCollector = FailureCollector()
        let pipeline = try TranscriptionChunkPipeline(
            configuration: .init(
                chunksDirectory: root.appendingPathComponent("chunks"),
                maxQueuedBytes: 8
            ),
            onFailure: { failureCollector.record($0) }
        )

        #expect(!pipeline.append(Data(repeating: 0, count: 12)))

        do {
            try await pipeline.finish()
            Issue.record("finish should report the terminal backlog error")
        } catch {
            #expect(
                error as? TranscriptionChunkPipeline.PipelineError
                    == .backlogExceeded(limitBytes: 8)
            )
        }
        #expect(failureCollector.failures == [.backlogExceeded(limitBytes: 8)])

        let entries = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("chunks"),
            includingPropertiesForKeys: nil
        )
        #expect(entries.isEmpty)
    }

    @Test
    func archiveRemainsCorrectWhenTranscriptionRejectsInput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = try TranscriptionChunkPipeline(
            configuration: .init(
                chunksDirectory: root.appendingPathComponent("chunks"),
                maxQueuedBytes: 8
            )
        )
        let archiveURL = root.appendingPathComponent("archive.wav")
        let writer = try WAVWriter(outputPath: archiveURL) { samples in
            _ = pipeline.append(samples)
        }
        let archivedPCM = Data((0..<16).map(UInt8.init))

        try writer.appendSamplesThrowing(archivedPCM)
        try writer.finalize()

        do {
            try await pipeline.finish()
            Issue.record("transcription rejection should remain observable")
        } catch {
            #expect(
                error as? TranscriptionChunkPipeline.PipelineError
                    == .backlogExceeded(limitBytes: 8)
            )
        }

        let archive = try Data(contentsOf: archiveURL)
        #expect(archive.count == 44 + archivedPCM.count)
        #expect(littleEndianUInt32(archive, at: 40) == UInt32(archivedPCM.count))
        #expect(archive.suffix(archivedPCM.count) == archivedPCM)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionChunkPipelineTests-\(UUID().uuidString)")
    }

    private func stereoPCM(seconds: Int, sampleRate: Int = 48_000) -> Data {
        let frameCount = seconds * sampleRate
        var data = Data(count: frameCount * 2 * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                let sample = Int16((frame % 200) - 100) * 100
                samples[frame * 2] = sample.littleEndian
                samples[frame * 2 + 1] = sample.littleEndian
            }
        }
        return data
    }

    private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChunks: [TranscriptionChunkPipeline.Chunk] = []
    private var storedReadyFilesExisted: [Bool] = []

    var chunks: [TranscriptionChunkPipeline.Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return storedChunks
    }

    var readyFilesExisted: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedReadyFilesExisted
    }

    func record(_ chunk: TranscriptionChunkPipeline.Chunk) {
        lock.lock()
        storedChunks.append(chunk)
        storedReadyFilesExisted.append(FileManager.default.fileExists(atPath: chunk.url.path))
        lock.unlock()
    }
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailures: [TranscriptionChunkPipeline.PipelineError] = []

    var failures: [TranscriptionChunkPipeline.PipelineError] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }

    func record(_ error: TranscriptionChunkPipeline.PipelineError) {
        lock.lock()
        storedFailures.append(error)
        lock.unlock()
    }
}
