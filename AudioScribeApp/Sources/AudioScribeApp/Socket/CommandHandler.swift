import Foundation

/// Handles JSON commands from socket clients
struct CommandHandler {
    enum Action: String, Codable {
        case start
        case stop
        case status
    }

    struct Command: Codable {
        let action: Action
        let output: String?
        let duration: Int?
        let systemAudio: Bool?
        let microphone: Bool?
    }

    struct Response: Codable {
        let success: Bool
        let recording: Bool
        let elapsedSeconds: Int?
        let outputPath: String?
        let error: String?
    }

    private let recordingState: RecordingState

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
    }

    @MainActor
    func handle(_ data: Data) async -> Data {
        // Parse command
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            return encodeResponse(Response(
                success: false,
                recording: recordingState.isRecording,
                elapsedSeconds: nil,
                outputPath: nil,
                error: "Invalid JSON command"
            ))
        }

        // Handle action
        switch command.action {
        case .start:
            return await handleStart(command)
        case .stop:
            return await handleStop()
        case .status:
            return handleStatus()
        }
    }

    @MainActor
    private func handleStart(_ command: Command) async -> Data {
        guard !recordingState.isRecording else {
            return encodeResponse(Response(
                success: false,
                recording: true,
                elapsedSeconds: Int(recordingState.elapsedTime),
                outputPath: recordingState.outputPath?.path,
                error: "Already recording"
            ))
        }

        // Apply settings from command
        if let systemAudio = command.systemAudio {
            recordingState.recordSystemAudio = systemAudio
        }
        if let microphone = command.microphone {
            recordingState.recordMicrophone = microphone
        }
        if let duration = command.duration {
            recordingState.duration = TimeInterval(duration)
        }

        // Determine output path
        var outputPath: URL?
        if let output = command.output {
            if output.hasPrefix("/") {
                outputPath = URL(fileURLWithPath: output)
            } else {
                let currentDir = FileManager.default.currentDirectoryPath
                outputPath = URL(fileURLWithPath: currentDir).appendingPathComponent(output)
            }
        }

        do {
            if let path = outputPath {
                try await recordingState.startRecording(outputPath: path)
            } else {
                try await recordingState.startRecording()
            }

            return encodeResponse(Response(
                success: true,
                recording: true,
                elapsedSeconds: 0,
                outputPath: recordingState.outputPath?.path,
                error: nil
            ))
        } catch {
            return encodeResponse(Response(
                success: false,
                recording: false,
                elapsedSeconds: nil,
                outputPath: nil,
                error: error.localizedDescription
            ))
        }
    }

    @MainActor
    private func handleStop() async -> Data {
        guard recordingState.isRecording else {
            return encodeResponse(Response(
                success: false,
                recording: false,
                elapsedSeconds: nil,
                outputPath: nil,
                error: "Not recording"
            ))
        }

        let elapsed = Int(recordingState.elapsedTime)
        let path = recordingState.outputPath?.path

        await recordingState.stopRecording()

        return encodeResponse(Response(
            success: true,
            recording: false,
            elapsedSeconds: elapsed,
            outputPath: path,
            error: nil
        ))
    }

    @MainActor
    private func handleStatus() -> Data {
        return encodeResponse(Response(
            success: true,
            recording: recordingState.isRecording,
            elapsedSeconds: recordingState.isRecording ? Int(recordingState.elapsedTime) : nil,
            outputPath: recordingState.outputPath?.path,
            error: nil
        ))
    }

    private func encodeResponse(_ response: Response) -> Data {
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}
