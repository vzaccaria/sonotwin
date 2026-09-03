import Foundation
import AVFoundation

// MARK: - @Observable State Container
// @Observable is a macro (new in macOS 14/iOS 17) that makes a class
// automatically notify SwiftUI when its properties change.
// This replaces the older ObservableObject + @Published pattern.
//
// @MainActor ensures all access happens on the main thread,
// which is required for UI-related state. Without this, SwiftUI
// updates could happen on background threads and crash.

@Observable
@MainActor
final class RecordingState {

    // MARK: - Recording Status
    // private(set) means: readable from outside, but only writable from inside this class.
    // This pattern exposes state for reading while controlling mutations.

    private(set) var isRecording = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputPath: URL?

    // MARK: - Audio Levels (0.0 to 1.0)
    // These are updated ~30 times per second by the RecordingEngine.
    // SwiftUI views observe these and automatically redraw when they change.

    private(set) var systemAudioLevel: Float = 0.0
    private(set) var microphoneLevel: Float = 0.0
    private(set) var systemAudioPeak: Float = 0.0
    private(set) var microphonePeak: Float = 0.0

    // MARK: - User Settings
    // These are read/write - the user can toggle them via the UI.
    // When the user changes these, any SwiftUI view using them updates automatically.

    var recordSystemAudio = true
    var recordMicrophone = true
    var duration: TimeInterval? = nil  // nil means "record until stopped"

    // MARK: - Default Output Directory
    // Computed property - calculated fresh each time it's accessed.
    // Uses the user's Documents folder as the default save location.

    var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Internal References
    // These are implementation details, not exposed to the UI.

    private var recordingEngine: RecordingEngine?
    private var elapsedTimer: Timer?
    private var startTime: Date?

    // MARK: - Permission Manager
    // The permission manager is also @Observable, so the UI can react
    // to permission state changes (e.g., show "Granted" when permission is given).

    let permissionManager = PermissionManager()

    // MARK: - Methods

    /// Called by AppDelegate to inject the recording engine dependency.
    /// This pattern (dependency injection) makes testing easier.
    func setRecordingEngine(_ engine: RecordingEngine) {
        self.recordingEngine = engine
    }

    /// Start recording to the given path, or auto-generate a timestamped filename.
    /// 'async throws' means this function is asynchronous and can fail with an error.
    func startRecording(outputPath: URL? = nil) async throws {
        // Guard statement: exit early if condition is false.
        // This is cleaner than nested if statements.
        guard !isRecording else { return }
        guard let engine = recordingEngine else {
            throw NSError(domain: "RecordingState", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recording engine not initialized"])
        }

        // Use provided path or generate one with a timestamp.
        let path = outputPath ?? generateOutputPath()
        self.outputPath = path

        // 'try await' - wait for async operation that might fail.
        try await engine.startRecording(
            to: path,
            recordSystemAudio: recordSystemAudio,
            recordMicrophone: recordMicrophone,
            duration: duration,
            transcriptionPipeline: nil
        )

        isRecording = true
        startTime = Date()
        elapsedTime = 0

        // Start a timer that fires every 0.1 seconds to update elapsed time.
        // [weak self] prevents a retain cycle - the timer doesn't keep this object alive.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Must dispatch to MainActor since timer callbacks are on the main thread
            // but our @MainActor isolation requires explicit Task for safety.
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }
    }

    /// Stop the current recording and finalize the output file.
    func stopRecording() async {
        guard isRecording else { return }

        // Invalidate (stop) the timer and release it.
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        await recordingEngine?.stopRecording()

        // Reset state for next recording.
        isRecording = false
        systemAudioLevel = 0
        microphoneLevel = 0
        systemAudioPeak = 0
        microphonePeak = 0
    }

    /// Called by RecordingEngine to update audio levels for VU meters.
    /// Converts linear RMS values to normalized dB scale (0.0 to 1.0).
    func updateLevels(systemRMS: Float, systemPeak: Float, micRMS: Float, micPeak: Float) {
        // Convert linear amplitude to dB, then normalize to 0-1 range.
        // log10 gives us decibels: dB = 20 * log10(amplitude)
        // LevelMeter.minDB is -60, so silence maps to 0.0 and full scale to 1.0.
        systemAudioLevel = LevelMeter.dbToNormalized(systemRMS > 0 ? 20 * log10(systemRMS) : LevelMeter.minDB)
        systemAudioPeak = LevelMeter.dbToNormalized(systemPeak > 0 ? 20 * log10(systemPeak) : LevelMeter.minDB)
        microphoneLevel = LevelMeter.dbToNormalized(micRMS > 0 ? 20 * log10(micRMS) : LevelMeter.minDB)
        microphonePeak = LevelMeter.dbToNormalized(micPeak > 0 ? 20 * log10(micPeak) : LevelMeter.minDB)
    }

    // MARK: - Private Helpers

    private func updateElapsedTime() {
        guard let startTime = startTime else { return }
        elapsedTime = Date().timeIntervalSince(startTime)

        // Auto-stop if a duration limit was set.
        if let duration = duration, elapsedTime >= duration {
            Task {
                await stopRecording()
            }
        }
    }

    /// Generate a filename like "recording_2024-01-15_14-30-45.wav"
    private func generateOutputPath() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return defaultOutputDirectory.appendingPathComponent("recording_\(timestamp).wav")
    }

    /// Format elapsed time as "MM:SS.T" for display in the UI.
    func formatElapsedTime() -> String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        // truncatingRemainder is Swift's modulo for floating point.
        let tenths = Int((elapsedTime.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}
