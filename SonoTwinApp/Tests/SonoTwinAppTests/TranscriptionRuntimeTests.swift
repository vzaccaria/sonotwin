import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct TranscriptionRuntimeTests {
    @Test
    func checksServerProcessesBothSourcesAndCompletesSession() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let fixture = try FakeWhisperFixture()
        defer { fixture.remove() }

        let statuses = RuntimeStatusCollector()
        let runtime = TranscriptionRuntime { statuses.record($0) }
        let settings = TranscriptionRuntime.Settings(
            executableURL: fixture.executableURL,
            modelURL: fixture.modelURL,
            requestedLanguage: "auto"
        )

        try await runtime.checkServer(settings: settings)
        #expect((await runtime.snapshot()).serverHealthy)

        let pipelines = try await runtime.startSession(
            recordingURL: fixture.root.appendingPathComponent("meeting.wav"),
            sources: [.microphone, .system],
            settings: settings
        )
        let samples = stereoPCM(seconds: 1)
        #expect(
            pipelines.append(
                samples,
                source: .microphone,
                firstSampleMilliseconds: 0
            )
        )
        #expect(
            pipelines.append(
                samples,
                source: .system,
                firstSampleMilliseconds: 100
            )
        )

        try await pipelines.finish()
        let draining = await runtime.beginFinishingSession()
        #expect(draining.state == .draining)
        do {
            _ = try await runtime.startSession(
                recordingURL: fixture.root.appendingPathComponent("too-soon.wav"),
                sources: [.microphone],
                settings: settings
            )
            Issue.record("a new session must not replace a draining session")
        } catch {
            #expect(
                error as? TranscriptionRuntime.RuntimeError
                    == .sessionAlreadyActive
            )
        }
        await runtime.finishSession()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .complete)
        #expect(snapshot.serverHealthy)
        #expect(snapshot.backlog == 0)
        #expect(snapshot.lagMilliseconds == 0)
        #expect(snapshot.lastCompletedSequence == 1)
        let transcriptURL = try #require(snapshot.transcriptURL)
        let jsonlURL = try #require(snapshot.jsonlURL)
        let bundleURL = try #require(snapshot.bundleURL)
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonlURL.path))
        #expect(!FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("chunks").path))

        let decoder = JSONDecoder()
        let records = try Data(contentsOf: jsonlURL).split(separator: 0x0A).map {
            try decoder.decode(TranscriptSessionStore.Record.self, from: Data($0))
        }
        #expect(Set(records.map(\.source)) == Set([.microphone, .system]))
        #expect(records.map(\.seq) == [0, 1])
        #expect(records.allSatisfy { $0.text == "prova" })
        #expect(statuses.contains(.checking))
        #expect(statuses.contains(.ready))
        #expect(statuses.contains(.active))
        #expect(statuses.contains(.draining))
        #expect(statuses.contains(.complete))

        await runtime.shutdown()
        #expect((await runtime.snapshot()).serverState == .stopped)
    }

    @Test
    func resumesPendingChunksAndRepairsTrailingJSONL() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let fixture = try FakeWhisperFixture()
        defer { fixture.remove() }
        let bundleURL = fixture.root.appendingPathComponent("interrupted.sonotwin")
        let firstChunk = try recoveryChunk(
            bundleURL: bundleURL,
            source: .system,
            sequence: 0,
            startMilliseconds: 0,
            endMilliseconds: 5_000
        )
        let pendingChunk = try recoveryChunk(
            bundleURL: bundleURL,
            source: .system,
            sequence: 1,
            startMilliseconds: 4_000,
            endMilliseconds: 10_000
        )

        do {
            let store = try TranscriptSessionStore(
                configuration: .init(
                    bundleURL: bundleURL,
                    recordingURL: fixture.root.appendingPathComponent("interrupted.wav"),
                    executableURL: fixture.executableURL,
                    modelURL: fixture.modelURL,
                    requestedLanguage: "auto"
                )
            )
            try await store.markProduced(firstChunk)
            _ = try await store.append(
                .init(
                    source: .system,
                    chunk: firstChunk,
                    language: "english",
                    durationSeconds: 1,
                    text: "first",
                    segments: [.init(startSeconds: 0, endSeconds: 1, text: "first")]
                )
            )
            try await store.markProduced(pendingChunk)
            try await store.setLifecycle(.incomplete, error: "interrupted")
        }

        let jsonlURL = bundleURL.appendingPathComponent("transcript.jsonl")
        let appendHandle = try FileHandle(forWritingTo: jsonlURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data("{partial".utf8))
        try appendHandle.close()

        let runtime = TranscriptionRuntime()
        let draining = try await runtime.recoverSession(
            bundleURL: bundleURL,
            settings: .init(
                executableURL: fixture.executableURL,
                modelURL: fixture.modelURL,
                requestedLanguage: "auto"
            )
        )
        #expect(draining.state == .draining)
        await runtime.finishSession()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .complete)
        #expect(snapshot.backlog == 0)
        #expect(snapshot.lastCompletedSequence == 1)
        let repairedJSONL = try Data(contentsOf: jsonlURL)
        let records = try repairedJSONL.split(separator: 0x0A).map {
            try JSONDecoder().decode(TranscriptSessionStore.Record.self, from: Data($0))
        }
        #expect(records.map(\.seq) == [0, 1])
        #expect(records.map(\.chunkSeq) == [0, 1])
        #expect(records.map(\.text) == ["first", "prova"])
        #expect(!String(decoding: repairedJSONL, as: UTF8.self).contains("partial"))
        #expect(!FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("chunks").path
        ))
        await runtime.shutdown()
    }

    @Test
    func invalidServerConfigurationBecomesActionableFailure() async throws {
        let statuses = RuntimeStatusCollector()
        let runtime = TranscriptionRuntime { statuses.record($0) }
        let missingExecutable = URL(fileURLWithPath: "/missing/whisper-server")

        do {
            try await runtime.checkServer(
                settings: .init(
                    executableURL: missingExecutable,
                    modelURL: URL(fileURLWithPath: "/missing/model.bin"),
                    requestedLanguage: "auto"
                )
            )
            Issue.record("missing server configuration must fail")
        } catch {
            #expect(
                error as? WhisperServerSupervisor.SupervisorError
                    == .executableNotRunnable(missingExecutable.path)
            )
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .failed)
        #expect(!snapshot.serverHealthy)
        #expect(snapshot.error?.contains(missingExecutable.path) == true)
        #expect(statuses.contains(.failed))
    }

    @Test
    func checksConfiguredRealServerHealth() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executablePath = environment["WHISPER_SERVER_PATH"],
              let modelPath = environment["WHISPER_MODEL_PATH"] else {
            return
        }

        let runtime = TranscriptionRuntime()
        try await runtime.checkServer(
            settings: .init(
                executableURL: URL(fileURLWithPath: executablePath),
                modelURL: URL(fileURLWithPath: modelPath),
                requestedLanguage: "auto"
            )
        )
        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.serverState == .ready)
        #expect(snapshot.serverHealthy)
        await runtime.shutdown()
        #expect((await runtime.snapshot()).serverState == .stopped)
    }

    private func recoveryChunk(
        bundleURL: URL,
        source: TranscriptionSource,
        sequence: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) throws -> TranscriptionChunkPipeline.Chunk {
        let sourceURL = bundleURL
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(source.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        let name = String(
            format: "%06d_%012lld_%012lld.wav",
            sequence,
            startMilliseconds,
            endMilliseconds
        )
        let url = sourceURL.appendingPathComponent(name)
        try Data("RIFF-fake".utf8).write(to: url)
        return .init(
            source: source,
            sequence: sequence,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            url: url
        )
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

private final class RuntimeStatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TranscriptionRuntime.State] = []

    func record(_ snapshot: TranscriptionRuntime.Snapshot) {
        lock.lock()
        states.append(snapshot.state)
        lock.unlock()
    }

    func contains(_ state: TranscriptionRuntime.State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states.contains(state)
    }
}
