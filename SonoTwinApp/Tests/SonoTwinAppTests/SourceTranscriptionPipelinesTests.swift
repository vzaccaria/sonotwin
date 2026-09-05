import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct SourceTranscriptionPipelinesTests {
    @Test
    func routesCombinedCaptureIntoIndependentComparableStreams() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let chunksRoot = root.appendingPathComponent("chunks")
        let collector = SourceChunkCollector()
        let pipelines = try SourceTranscriptionPipelines(
            configuration: .init(
                rootDirectory: chunksRoot,
                sources: [.microphone, .system]
            ),
            onChunkReady: { collector.record($0) }
        )
        let samples = stereoPCM(seconds: 1)

        #expect(
            pipelines.append(
                samples,
                source: .microphone,
                firstSampleMilliseconds: 120
            )
        )
        #expect(
            pipelines.append(
                samples,
                source: .system,
                firstSampleMilliseconds: 260
            )
        )
        try await pipelines.finish()

        let chunks = collector.chunks.sorted { $0.source.rawValue < $1.source.rawValue }
        #expect(chunks.count == 2)
        #expect(chunks.map(\.source) == [.microphone, .system])
        #expect(chunks.map(\.sequence) == [0, 0])
        #expect(chunks.map(\.startMilliseconds) == [120, 260])
        #expect(chunks.map(\.endMilliseconds) == [1_120, 1_260])
        #expect(
            chunks.allSatisfy {
                $0.url.deletingLastPathComponent().lastPathComponent == $0.source.rawValue
            }
        )

        let sourceDirectories = try FileManager.default.contentsOfDirectory(
            at: chunksRoot,
            includingPropertiesForKeys: nil
        )
        #expect(Set(sourceDirectories.map(\.lastPathComponent)) == Set(["microphone", "system"]))
    }

    @Test
    func singleSourceConfigurationRejectsUnselectedInput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = SourceChunkCollector()
        let pipelines = try SourceTranscriptionPipelines(
            configuration: .init(
                rootDirectory: root,
                sources: [.microphone]
            ),
            onChunkReady: { collector.record($0) }
        )
        let samples = stereoPCM(seconds: 1)

        #expect(pipelines.contains(.microphone))
        #expect(!pipelines.contains(.system))
        #expect(
            pipelines.append(
                samples,
                source: .microphone,
                firstSampleMilliseconds: 0
            )
        )
        #expect(
            !pipelines.append(
                samples,
                source: .system,
                firstSampleMilliseconds: 0
            )
        )
        try await pipelines.finish()

        #expect(collector.chunks.map(\.source) == [.microphone])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("system").path))
    }

    @Test
    func sourceBacklogDoesNotPreventArchiveOrOtherSourceFinalization() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = SourceChunkCollector()
        let pipelines = try SourceTranscriptionPipelines(
            configuration: .init(
                rootDirectory: root.appendingPathComponent("chunks"),
                sources: [.microphone, .system],
                maxQueuedBytesPerSource: 200_000
            ),
            onChunkReady: { collector.record($0) }
        )
        let archivedPCM = Data(repeating: 7, count: 200_004)
        let archiveURL = root.appendingPathComponent("archive.wav")
        let writer = try WAVWriter(outputPath: archiveURL)

        #expect(
            !pipelines.append(
                archivedPCM,
                source: .microphone,
                firstSampleMilliseconds: 0
            )
        )
        #expect(
            pipelines.append(
                stereoPCM(seconds: 1),
                source: .system,
                firstSampleMilliseconds: 80
            )
        )
        try writer.appendSamplesThrowing(archivedPCM)
        try writer.finalize()

        do {
            try await pipelines.finish()
            Issue.record("the rejected source must remain observable")
        } catch {
            #expect(
                error as? TranscriptionChunkPipeline.PipelineError
                    == .backlogExceeded(limitBytes: 200_000)
            )
        }

        let archive = try Data(contentsOf: archiveURL)
        #expect(archive.count == 44 + archivedPCM.count)
        #expect(archive.suffix(archivedPCM.count) == archivedPCM)
        #expect(collector.chunks.map(\.source) == [.system])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceTranscriptionPipelinesTests-\(UUID().uuidString)")
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
}

private final class SourceChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChunks: [TranscriptionChunkPipeline.Chunk] = []

    var chunks: [TranscriptionChunkPipeline.Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return storedChunks
    }

    func record(_ chunk: TranscriptionChunkPipeline.Chunk) {
        lock.lock()
        storedChunks.append(chunk)
        lock.unlock()
    }
}
