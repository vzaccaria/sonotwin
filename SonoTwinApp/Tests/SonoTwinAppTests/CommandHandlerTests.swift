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
