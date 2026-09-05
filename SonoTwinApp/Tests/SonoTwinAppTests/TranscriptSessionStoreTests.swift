import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct TranscriptSessionStoreTests {
    @Test
    func writesSourceAwareJSONLAndRemovesOverlapDuplicates() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)

        let firstChunk = chunk(
            source: .microphone,
            sequence: 0,
            startMilliseconds: 0,
            endMilliseconds: 5_000,
            root: root
        )
        try await store.markProduced(firstChunk)
        let firstRecords = try await store.append(
            inference(
                chunk: firstChunk,
                text: "hello world how are",
                segments: [
                    .init(startSeconds: 0, endSeconds: 3, text: "hello world"),
                    .init(startSeconds: 3, endSeconds: 5, text: "how are")
                ]
            )
        )

        let overlapChunk = chunk(
            source: .microphone,
            sequence: 1,
            startMilliseconds: 4_000,
            endMilliseconds: 10_000,
            root: root
        )
        try await store.markProduced(overlapChunk)
        let overlapRecords = try await store.append(
            inference(
                chunk: overlapChunk,
                text: "are you today",
                segments: [
                    .init(startSeconds: 0, endSeconds: 2, text: "are you"),
                    .init(startSeconds: 2, endSeconds: 5, text: "today")
                ]
            )
        )

        #expect(firstRecords.map(\.text) == ["hello world", "how are"])
        #expect(overlapRecords.map(\.text) == ["you", "today"])
        #expect(overlapRecords.map(\.startMs) == [5_000, 6_000])
        #expect(overlapRecords.map(\.endMs) == [6_000, 9_000])

        let records = try decodedRecords(at: await store.jsonlURL)
        #expect(records.map(\.seq) == [0, 1, 2, 3])
        #expect(records.allSatisfy { $0.v == 1 && $0.final })
        #expect(records.allSatisfy { $0.source == .microphone })
        #expect(records.map(\.text).joined(separator: " ") == "hello world how are you today")

        let transcript = try String(contentsOf: await store.transcriptURL, encoding: .utf8)
        #expect(transcript.contains("[microphone] hello world"))
        #expect(transcript.contains("[microphone] you"))
        #expect(!transcript.contains("are are"))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("meeting.sonotwin/session.json.part").path
            )
        )
    }

    @Test
    func reconcilesOverlapIndependentlyPerSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)

        let microphone = chunk(
            source: .microphone,
            sequence: 0,
            startMilliseconds: 0,
            endMilliseconds: 5_000,
            root: root
        )
        let system = chunk(
            source: .system,
            sequence: 0,
            startMilliseconds: 0,
            endMilliseconds: 5_000,
            root: root
        )

        _ = try await store.append(
            inference(
                chunk: microphone,
                text: "shared phrase",
                segments: [.init(startSeconds: 0, endSeconds: 2, text: "shared phrase")]
            )
        )
        _ = try await store.append(
            inference(
                chunk: system,
                text: "shared phrase",
                segments: [.init(startSeconds: 0, endSeconds: 2, text: "shared phrase")]
            )
        )

        let records = try decodedRecords(at: await store.jsonlURL)
        #expect(records.map(\.source) == [.microphone, .system])
        #expect(records.map(\.text) == ["shared phrase", "shared phrase"])
    }

    @Test
    func recoversCompleteLinesAndSkipsTranscribedChunks() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = try makeStore(root: root)
        let firstChunk = chunk(
            source: .system,
            sequence: 0,
            startMilliseconds: 0,
            endMilliseconds: 5_000,
            root: root
        )
        _ = try await firstStore.append(
            inference(
                chunk: firstChunk,
                text: "first",
                segments: [.init(startSeconds: 0, endSeconds: 1, text: "first")]
            )
        )
        try await firstStore.setLifecycle(.incomplete, error: "interrupted")

        let jsonlURL = await firstStore.jsonlURL
        let appendHandle = try FileHandle(forWritingTo: jsonlURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data("{partial".utf8))
        try appendHandle.close()

        let recoveredStore = try makeStore(root: root)
        #expect(await recoveredStore.isTranscribed(firstChunk))
        #expect(try await recoveredStore.append(inference(chunk: firstChunk, text: "duplicate")) == [])

        let secondChunk = chunk(
            source: .system,
            sequence: 1,
            startMilliseconds: 4_000,
            endMilliseconds: 10_000,
            root: root
        )
        let appended = try await recoveredStore.append(
            inference(
                chunk: secondChunk,
                text: "second",
                segments: [.init(startSeconds: 1, endSeconds: 2, text: "second")]
            )
        )

        #expect(appended.map(\.seq) == [1])
        #expect(try decodedRecords(at: jsonlURL).map(\.text) == ["first", "second"])
        let transcript = try String(contentsOf: await recoveredStore.transcriptURL, encoding: .utf8)
        #expect(transcript.contains("first"))
        #expect(transcript.contains("second"))
        #expect(!transcript.contains("partial"))
    }

    private func makeStore(root: URL) throws -> TranscriptSessionStore {
        try TranscriptSessionStore(
            configuration: .init(
                bundleURL: root.appendingPathComponent("meeting.sonotwin"),
                recordingURL: root.appendingPathComponent("meeting.wav"),
                executableURL: URL(fileURLWithPath: "/tmp/whisper-server"),
                modelURL: URL(fileURLWithPath: "/tmp/model.bin"),
                requestedLanguage: "auto"
            )
        )
    }

    private func chunk(
        source: TranscriptionSource,
        sequence: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        root: URL
    ) -> TranscriptionChunkPipeline.Chunk {
        .init(
            source: source,
            sequence: sequence,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            url: root.appendingPathComponent("\(source.rawValue)-\(sequence).wav")
        )
    }

    private func inference(
        chunk: TranscriptionChunkPipeline.Chunk,
        text: String,
        segments: [WhisperServerSupervisor.Segment] = []
    ) -> WhisperServerSupervisor.Inference {
        .init(
            source: chunk.source,
            chunk: chunk,
            language: "italian",
            durationSeconds: Double(chunk.endMilliseconds - chunk.startMilliseconds) / 1_000,
            text: text,
            segments: segments
        )
    }

    private func decodedRecords(at url: URL) throws -> [TranscriptSessionStore.Record] {
        let decoder = JSONDecoder()
        return try Data(contentsOf: url).split(separator: 0x0A).map {
            try decoder.decode(TranscriptSessionStore.Record.self, from: Data($0))
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSessionStoreTests-\(UUID().uuidString)")
    }
}
