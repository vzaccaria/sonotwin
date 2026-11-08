import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct CommandHandlerTests {
    @Test @MainActor
    func statusExposesTheSameTranscriptionSnapshotUsedByTheUI() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let state = RecordingState(userDefaults: defaults)
        state.transcriptionEnabled = true
        state.updateTranscriptionStatus(
            .init(
                state: .lagging,
                serverState: .ready,
                serverHealthy: true,
                bundleURL: URL(fileURLWithPath: "/tmp/meeting.sonotwin"),
                transcriptURL: URL(fileURLWithPath: "/tmp/meeting.sonotwin/transcript.txt"),
                jsonlURL: URL(fileURLWithPath: "/tmp/meeting.sonotwin/transcript.jsonl"),
                lastCompletedSequence: 12,
                backlog: 3,
                lagMilliseconds: 11_500,
                error: nil
            )
        )

        let responseData = await CommandHandler(recordingState: state).handle(
            Data(#"{"action":"status"}"#.utf8)
        )
        let response = try JSONDecoder().decode(CommandHandler.Response.self, from: responseData)

        #expect(response.success)
        #expect(!response.recording)
        #expect(response.transcription.enabled)
        #expect(response.transcription.state == .lagging)
        #expect(response.transcription.serverState == "ready")
        #expect(response.transcription.serverHealthy)
        #expect(response.transcription.transcriptPath == "/tmp/meeting.sonotwin/transcript.txt")
        #expect(response.transcription.lastCompletedSequence == 12)
        #expect(response.transcription.backlog == 3)
        #expect(response.transcription.lagMilliseconds == 11_500)
    }

    @Test @MainActor
    func startCommandAppliesTranscriptionConfigurationBeforeRecording() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let state = RecordingState(userDefaults: defaults)
        let command = Data(
            #"{"action":"start","transcription":true,"whisperExecutable":"/tmp/server","whisperModel":"/tmp/model.bin","language":"it"}"#.utf8
        )

        let responseData = await CommandHandler(recordingState: state).handle(command)
        let response = try JSONDecoder().decode(CommandHandler.Response.self, from: responseData)

        #expect(!response.success)
        #expect(response.error == "Recording engine not initialized")
        #expect(state.transcriptionEnabled)
        #expect(state.whisperExecutablePath == "/tmp/server")
        #expect(state.whisperModelPath == "/tmp/model.bin")
        #expect(state.transcriptionLanguage == "it")
    }

    @Test @MainActor
    func stopPublishesFinalizedRecordingWhileTranscriptKeepsDraining() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandHandlerStopTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipelines = try SourceTranscriptionPipelines(
            configuration: .init(
                rootDirectory: root.appendingPathComponent("chunks"),
                sources: [.microphone]
            )
        )
        let engine = RecordingEngineStub()
        let runtime = TranscriptionRuntimeStub(
            pipelines: pipelines,
            snapshot: .init(
                state: .draining,
                serverState: .ready,
                serverHealthy: true,
                bundleURL: root.appendingPathComponent("meeting.sonotwin"),
                transcriptURL: root.appendingPathComponent("meeting.sonotwin/transcript.txt"),
                jsonlURL: root.appendingPathComponent("meeting.sonotwin/transcript.jsonl"),
                lastCompletedSequence: 7,
                backlog: 4,
                lagMilliseconds: 20_000,
                error: nil
            )
        )
        let state = RecordingState(userDefaults: defaults)
        state.transcriptionEnabled = true
        state.whisperExecutablePath = "/tmp/fake-whisper-server"
        state.whisperModelPath = "/tmp/fake-model.bin"
        state.setRecordingEngine(engine)
        state.setTranscriptionRuntime(runtime)
        let output = root.appendingPathComponent("meeting.wav")
        try await state.startRecording(outputPath: output)
        let bundleURL = root.appendingPathComponent("meeting.sonotwin")
        #expect(
            defaults.string(forKey: RecordingState.activeTranscriptionBundlePathKey)
                == bundleURL.path
        )

        let stopData = await CommandHandler(recordingState: state).handle(
            Data(#"{"action":"stop"}"#.utf8)
        )
        let stopResponse = try JSONDecoder().decode(
            CommandHandler.Response.self,
            from: stopData
        )

        #expect(stopResponse.success)
        #expect(!stopResponse.recording)
        #expect(stopResponse.outputPath == output.path)
        #expect(stopResponse.transcription.state == .draining)
        #expect(stopResponse.transcription.backlog == 4)
        #expect(!state.isRecording)
        #expect(!state.isStopping)
        #expect(!state.canStartRecording)
        let engineCountsAfterStop = await engine.counts()
        let runtimeCountsAfterStop = await runtime.counts()
        #expect(engineCountsAfterStop == .init(starts: 1, stops: 1))
        #expect(runtimeCountsAfterStop == .init(starts: 1, begins: 1, finishes: 0))

        let restartData = await CommandHandler(recordingState: state).handle(
            Data(#"{"action":"start","transcription":true}"#.utf8)
        )
        let restartResponse = try JSONDecoder().decode(
            CommandHandler.Response.self,
            from: restartData
        )
        #expect(!restartResponse.success)
        #expect(restartResponse.error == "Previous transcript is still finishing")
        let engineCountsAfterRestart = await engine.counts()
        #expect(engineCountsAfterRestart.starts == 1)

        try await pipelines.finish()
        await state.shutdownTranscription()
        state.updateTranscriptionStatus(
            .init(
                state: .complete,
                serverState: .ready,
                serverHealthy: true,
                bundleURL: bundleURL,
                transcriptURL: bundleURL.appendingPathComponent("transcript.txt"),
                jsonlURL: bundleURL.appendingPathComponent("transcript.jsonl"),
                lastCompletedSequence: 7,
                backlog: 0,
                lagMilliseconds: 0,
                error: nil
            )
        )
        #expect(
            defaults.string(forKey: RecordingState.activeTranscriptionBundlePathKey) == nil
        )
    }

    @Test @MainActor
    func freshSettingsDefaultToAutomaticLanguageDetection() {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let state = RecordingState(userDefaults: defaults)

        #expect(state.transcriptionLanguage == "auto")
    }

    @Test @MainActor
    func persistsExplicitAndAutomaticLanguageChoices() {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let state = RecordingState(userDefaults: defaults)
        state.transcriptionLanguage = "it"
        #expect(RecordingState(userDefaults: defaults).transcriptionLanguage == "it")

        state.transcriptionLanguage = "auto"
        #expect(RecordingState(userDefaults: defaults).transcriptionLanguage == "auto")
    }

    private func temporaryDefaults() -> UserDefaults {
        let name = "CommandHandlerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(name, forKey: "suiteName")
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "suiteName")!
    }
}

private actor RecordingEngineStub: RecordingEngineProtocol {
    struct Counts: Equatable, Sendable {
        let starts: Int
        let stops: Int
    }

    private var startCount = 0
    private var stopCount = 0

    func startRecording(
        to outputURL: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        microphoneDeviceID: String?,
        duration: TimeInterval?,
        transcriptionPipelines: SourceTranscriptionPipelines?
    ) async throws -> String? {
        startCount += 1
        return nil
    }

    func stopRecording() async {
        stopCount += 1
    }

    func counts() -> Counts {
        Counts(starts: startCount, stops: stopCount)
    }
}

private actor TranscriptionRuntimeStub: TranscriptionRuntimeProtocol {
    struct Counts: Equatable, Sendable {
        let starts: Int
        let begins: Int
        let finishes: Int
    }

    private let pipelines: SourceTranscriptionPipelines
    private let drainingSnapshot: TranscriptionRuntime.Snapshot
    private var startCount = 0
    private var beginCount = 0
    private var finishCount = 0

    init(
        pipelines: SourceTranscriptionPipelines,
        snapshot: TranscriptionRuntime.Snapshot
    ) {
        self.pipelines = pipelines
        self.drainingSnapshot = snapshot
    }

    func checkServer(settings: TranscriptionRuntime.Settings) async throws {}

    func startSession(
        recordingURL: URL,
        sources: Set<TranscriptionSource>,
        settings: TranscriptionRuntime.Settings
    ) async throws -> SourceTranscriptionPipelines {
        startCount += 1
        return pipelines
    }

    func recoverSession(
        bundleURL: URL,
        settings: TranscriptionRuntime.Settings
    ) async throws -> TranscriptionRuntime.Snapshot {
        drainingSnapshot
    }

    func beginFinishingSession() -> TranscriptionRuntime.Snapshot {
        beginCount += 1
        return drainingSnapshot
    }

    func finishSession() async {
        finishCount += 1
    }

    func snapshot() -> TranscriptionRuntime.Snapshot {
        drainingSnapshot
    }

    func shutdown() async {}

    func counts() -> Counts {
        Counts(starts: startCount, begins: beginCount, finishes: finishCount)
    }
}
