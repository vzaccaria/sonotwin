import Foundation

// MARK: - CommandHandler
// Processes JSON commands from the Unix socket and returns JSON responses.
// This allows the ascribe-ctl CLI tool to control the app remotely.
//
// Protocol: Commands and responses are JSON objects.
// Command:  {"action": "start|stop|status", "output": "/path", "duration": 30}
// Response: {"success": true, "recording": true, "elapsedSeconds": 42, ...}

struct CommandHandler {

    // MARK: - Protocol Types
    // These enums and structs define the JSON schema.
    // Codable allows automatic JSON encoding/decoding.

    /// Possible actions the client can request.
    enum Action: String, Codable {
        case start   // Begin recording
        case stop    // Stop recording
        case status  // Query current state
    }

    /// Incoming command structure.
    /// All fields except 'action' are optional.
    struct Command: Codable {
        let action: Action
        let output: String?       // Output file path
        let duration: Int?        // Recording duration in seconds
        let systemAudio: Bool?    // Record system audio?
        let microphone: Bool?     // Record microphone?
    }

    /// Outgoing response structure.
    struct Response: Codable {
        let success: Bool         // Did the command succeed?
        let recording: Bool       // Is currently recording?
        let elapsedSeconds: Int?  // Seconds since recording started
        let outputPath: String?   // Path to output file
        let error: String?        // Error message if failed
    }

    // MARK: - Properties

    private let recordingState: RecordingState

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
    }

    // MARK: - Command Processing

    /// Parse and handle a command, returning a response.
    /// @MainActor because RecordingState is MainActor-isolated.
    @MainActor
    func handle(_ data: Data) async -> Data {
        // Try to parse the JSON command.
        // 'try?' returns nil on failure instead of throwing.
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            return encodeResponse(Response(
                success: false,
                recording: recordingState.isRecording,
                elapsedSeconds: nil,
                outputPath: nil,
                error: "Invalid JSON command"
            ))
        }

        // Dispatch to the appropriate handler based on action.
        switch command.action {
        case .start:
            return await handleStart(command)
        case .stop:
            return await handleStop()
        case .status:
            return handleStatus()
        }
    }

    // MARK: - Action Handlers

    /// Handle "start" command - begin recording.
    @MainActor
    private func handleStart(_ command: Command) async -> Data {
        // Can't start if already recording.
        guard !recordingState.isRecording else {
            return encodeResponse(Response(
                success: false,
                recording: true,
                elapsedSeconds: Int(recordingState.elapsedTime),
                outputPath: recordingState.outputPath?.path,
                error: "Already recording"
            ))
        }

        // Apply settings from the command (if provided).
        if let systemAudio = command.systemAudio {
            recordingState.recordSystemAudio = systemAudio
        }
        if let microphone = command.microphone {
            recordingState.recordMicrophone = microphone
        }
        if let duration = command.duration {
            recordingState.duration = TimeInterval(duration)
        }

        // Determine output path.
        // If relative path, make it relative to current directory.
        var outputPath: URL?
        if let output = command.output {
            if output.hasPrefix("/") {
                // Absolute path - use as-is.
                outputPath = URL(fileURLWithPath: output)
            } else {
                // Relative path - resolve from current directory.
                let currentDir = FileManager.default.currentDirectoryPath
                outputPath = URL(fileURLWithPath: currentDir).appendingPathComponent(output)
            }
        }

        // Start recording.
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

    /// Handle "stop" command - stop recording.
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

        // Capture values before stopping (they'll be reset).
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

    /// Handle "status" command - return current state.
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

    // MARK: - Helper

    /// Encode a response to JSON data.
    private func encodeResponse(_ response: Response) -> Data {
        // JSONEncoder converts Codable structs to JSON Data.
        // 'try?' returns empty Data on encoding failure.
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}
