import Foundation

/// Processes newline-delimited JSON commands received over the Unix socket.
struct CommandHandler {
    enum Action: String, Codable {
        case start
        case stop
        case status
        case checkTranscription
    }

    struct Command: Codable {
        let action: Action
        let output: String?
        let duration: Int?
        let systemAudio: Bool?
        let microphone: Bool?
        let transcription: Bool?
        let whisperExecutable: String?
        let whisperModel: String?
        let language: String?
    }

    struct TranscriptionStatus: Codable, Equatable {
        let enabled: Bool
        let state: TranscriptionRuntime.State
        let serverState: String
        let serverHealthy: Bool
        let bundlePath: String?
        let transcriptPath: String?
        let jsonlPath: String?
        let lastCompletedSequence: Int?
        let backlog: Int
        let lagMilliseconds: Int64
        let error: String?
    }

    struct Response: Codable, Equatable {
        let success: Bool
        let recording: Bool
        let elapsedSeconds: Int?
        let outputPath: String?
        let error: String?
        let transcription: TranscriptionStatus
    }

    private let recordingState: RecordingState

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
    }

    @MainActor
    func handle(_ data: Data) async -> Data {
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            return encodeResponse(
                makeResponse(
                    success: false,
                    elapsedSeconds: nil,
                    outputPath: nil,
                    error: "Invalid JSON command"
                )
            )
        }

        switch command.action {
        case .start:
            return await handleStart(command)
        case .stop:
            return await handleStop()
        case .status:
            return encodeResponse(makeResponse(success: true))
        case .checkTranscription:
            await recordingState.checkTranscriptionServer()
            let healthy = recordingState.transcriptionSnapshot.serverHealthy
            return encodeResponse(
                makeResponse(
                    success: healthy,
                    error: healthy ? nil : recordingState.transcriptionError
                )
            )
        }
    }

    @MainActor
    private func handleStart(_ command: Command) async -> Data {
        guard !recordingState.isRecording else {
            return encodeResponse(
                makeResponse(
                    success: false,
                    elapsedSeconds: Int(recordingState.elapsedTime),
                    error: "Already recording"
                )
            )
        }

        if let systemAudio = command.systemAudio {
            recordingState.recordSystemAudio = systemAudio
        }
        if let microphone = command.microphone {
            recordingState.recordMicrophone = microphone
        }
        if let duration = command.duration {
            recordingState.duration = TimeInterval(duration)
        }
        if let transcription = command.transcription {
            recordingState.transcriptionEnabled = transcription
        }
        if let executable = command.whisperExecutable {
            recordingState.whisperExecutablePath = executable
        }
        if let model = command.whisperModel {
            recordingState.whisperModelPath = model
        }
        if let language = command.language {
            recordingState.transcriptionLanguage = language
        }

        let outputPath: URL?
        if let output = command.output {
            if output.hasPrefix("/") {
                outputPath = URL(fileURLWithPath: output)
            } else {
                outputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(output)
            }
        } else {
            outputPath = nil
        }

        do {
            try await recordingState.startRecording(outputPath: outputPath)
            return encodeResponse(
                makeResponse(
                    success: true,
                    elapsedSeconds: 0,
                    outputPath: recordingState.outputPath?.path
                )
            )
        } catch {
            return encodeResponse(
                makeResponse(
                    success: false,
                    elapsedSeconds: nil,
                    outputPath: nil,
                    error: error.localizedDescription
                )
            )
        }
    }

    @MainActor
    private func handleStop() async -> Data {
        guard recordingState.isRecording else {
            return encodeResponse(
                makeResponse(
                    success: false,
                    elapsedSeconds: nil,
                    outputPath: nil,
                    error: "Not recording"
                )
            )
        }

        let elapsed = Int(recordingState.elapsedTime)
        let path = recordingState.outputPath?.path
        await recordingState.stopRecording()
        return encodeResponse(
            makeResponse(
                success: true,
                elapsedSeconds: elapsed,
                outputPath: path
            )
        )
    }

    @MainActor
    private func makeResponse(
        success: Bool,
        elapsedSeconds: Int? = nil,
        outputPath: String? = nil,
        error: String? = nil
    ) -> Response {
        let snapshot = recordingState.transcriptionSnapshot
        return Response(
            success: success,
            recording: recordingState.isRecording,
            elapsedSeconds: elapsedSeconds
                ?? (recordingState.isRecording ? Int(recordingState.elapsedTime) : nil),
            outputPath: outputPath ?? recordingState.outputPath?.path,
            error: error,
            transcription: TranscriptionStatus(
                enabled: recordingState.transcriptionEnabled,
                state: recordingState.transcriptionDisplayState,
                serverState: Self.serverStateDescription(snapshot.serverState),
                serverHealthy: snapshot.serverHealthy,
                bundlePath: snapshot.bundleURL?.path,
                transcriptPath: snapshot.transcriptURL?.path,
                jsonlPath: snapshot.jsonlURL?.path,
                lastCompletedSequence: snapshot.lastCompletedSequence,
                backlog: snapshot.backlog,
                lagMilliseconds: snapshot.lagMilliseconds,
                error: recordingState.transcriptionError
            )
        )
    }

    private func encodeResponse(_ response: Response) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)) ?? Data()
    }

    private static func serverStateDescription(
        _ state: WhisperServerSupervisor.State
    ) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .ready: return "ready"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }
}
