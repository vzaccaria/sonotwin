import Foundation
import AVFoundation

/// Observable state container for recording status and settings
@Observable
@MainActor
final class RecordingState {
    // MARK: - Recording Status
    private(set) var isRecording = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputPath: URL?

    // MARK: - Audio Levels (0.0 to 1.0)
    private(set) var systemAudioLevel: Float = 0.0
    private(set) var microphoneLevel: Float = 0.0
    private(set) var systemAudioPeak: Float = 0.0
    private(set) var microphonePeak: Float = 0.0

    // MARK: - Settings
    var recordSystemAudio = true
    var recordMicrophone = true
    var duration: TimeInterval? = nil // nil = unlimited

    // MARK: - Default Output Directory
    var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Recording Engine Reference
    private var recordingEngine: RecordingEngine?
    private var elapsedTimer: Timer?
    private var startTime: Date?

    // MARK: - Permission Manager
    let permissionManager = PermissionManager()

    // MARK: - Methods

    func setRecordingEngine(_ engine: RecordingEngine) {
        self.recordingEngine = engine
    }

    func startRecording(outputPath: URL? = nil) async throws {
        guard !isRecording else { return }
        guard let engine = recordingEngine else {
            throw NSError(domain: "RecordingState", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording engine not initialized"])
        }

        // Determine output path
        let path = outputPath ?? generateOutputPath()
        self.outputPath = path

        // Configure and start engine
        try await engine.startRecording(
            to: path,
            recordSystemAudio: recordSystemAudio,
            recordMicrophone: recordMicrophone,
            duration: duration
        )

        isRecording = true
        startTime = Date()
        elapsedTime = 0

        // Start elapsed time timer
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        elapsedTimer?.invalidate()
        elapsedTimer = nil

        await recordingEngine?.stopRecording()

        isRecording = false
        systemAudioLevel = 0
        microphoneLevel = 0
        systemAudioPeak = 0
        microphonePeak = 0
    }

    func updateLevels(systemRMS: Float, systemPeak: Float, micRMS: Float, micPeak: Float) {
        systemAudioLevel = LevelMeter.dbToNormalized(systemRMS > 0 ? 20 * log10(systemRMS) : LevelMeter.minDB)
        systemAudioPeak = LevelMeter.dbToNormalized(systemPeak > 0 ? 20 * log10(systemPeak) : LevelMeter.minDB)
        microphoneLevel = LevelMeter.dbToNormalized(micRMS > 0 ? 20 * log10(micRMS) : LevelMeter.minDB)
        microphonePeak = LevelMeter.dbToNormalized(micPeak > 0 ? 20 * log10(micPeak) : LevelMeter.minDB)
    }

    private func updateElapsedTime() {
        guard let startTime = startTime else { return }
        elapsedTime = Date().timeIntervalSince(startTime)

        // Auto-stop if duration is set
        if let duration = duration, elapsedTime >= duration {
            Task {
                await stopRecording()
            }
        }
    }

    private func generateOutputPath() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return defaultOutputDirectory.appendingPathComponent("recording_\(timestamp).wav")
    }

    func formatElapsedTime() -> String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        let tenths = Int((elapsedTime.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}
