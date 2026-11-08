import Foundation
import AVFoundation

protocol RecordingEngineProtocol: Actor {
    func startRecording(
        to outputURL: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        microphoneDeviceID: String?,
        duration: TimeInterval?,
        transcriptionPipelines: SourceTranscriptionPipelines?
    ) async throws -> String?
    func stopRecording() async
}

extension RecordingEngine: RecordingEngineProtocol {}

protocol TranscriptionRuntimeProtocol: Actor {
    func checkServer(settings: TranscriptionRuntime.Settings) async throws
    func startSession(
        recordingURL: URL,
        sources: Set<TranscriptionSource>,
        settings: TranscriptionRuntime.Settings
    ) async throws -> SourceTranscriptionPipelines
    func recoverSession(
        bundleURL: URL,
        settings: TranscriptionRuntime.Settings
    ) async throws -> TranscriptionRuntime.Snapshot
    func beginFinishingSession() -> TranscriptionRuntime.Snapshot
    func finishSession() async
    func snapshot() -> TranscriptionRuntime.Snapshot
    func shutdown() async
}

extension TranscriptionRuntime: TranscriptionRuntimeProtocol {}

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
    private let userDefaults: UserDefaults
    static let activeTranscriptionBundlePathKey = "activeTranscriptionBundlePath"


    // MARK: - Recording Status
    // private(set) means: readable from outside, but only writable from inside this class.
    // This pattern exposes state for reading while controlling mutations.

    private(set) var isStopping = false
    private(set) var isRecording = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputPath: URL?
    /// Name of the microphone captured by the current recording.
    private(set) var activeMicrophoneName: String?

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
    /// `AVCaptureDevice.uniqueID` of the chosen microphone; empty = system default.
    var microphoneDeviceID: String {
        didSet { userDefaults.set(microphoneDeviceID, forKey: "microphoneDeviceID") }
    }

    /// Microphone the next recording will capture: the chosen device if it is
    /// connected, otherwise the system default (the fallback `MicrophoneCapture` uses).
    var plannedMicrophoneName: String? {
        if !microphoneDeviceID.isEmpty,
           let device = MicrophoneCapture.availableDevices().first(where: { $0.id == microphoneDeviceID }) {
            return device.name
        }
        return MicrophoneCapture.systemDefaultDevice()?.name
    }

    var transcriptionEnabled: Bool {
        didSet { userDefaults.set(transcriptionEnabled, forKey: "transcriptionEnabled") }
    }
    var whisperExecutablePath: String {
        didSet { userDefaults.set(whisperExecutablePath, forKey: "whisperExecutablePath") }
    }
    var whisperModelPath: String {
        didSet { userDefaults.set(whisperModelPath, forKey: "whisperModelPath") }
    }
    var transcriptionLanguage: String {
        didSet { userDefaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }
    private(set) var transcriptionSnapshot = TranscriptionRuntime.Snapshot.idle
    private(set) var transcriptionConfigurationError: String?

    // MARK: - Default Output Directory
    // Computed property - calculated fresh each time it's accessed.
    // Uses the user's Documents folder as the default save location.

    var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Internal References
    // These are implementation details, not exposed to the UI.

    private var recordingEngine: (any RecordingEngineProtocol)?
    private var elapsedTimer: Timer?
    private var transcriptionRuntime: (any TranscriptionRuntimeProtocol)?
    private var sessionTranscriptionActive = false
    private var startTime: Date?

    // MARK: - Permission Manager
    // The permission manager is also @Observable, so the UI can react
    // to permission state changes (e.g., show "Granted" when permission is given).

    let permissionManager = PermissionManager()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaults = userDefaults
        transcriptionEnabled = defaults.object(forKey: "transcriptionEnabled") as? Bool ?? false
        whisperExecutablePath = defaults.string(forKey: "whisperExecutablePath")
            ?? Self.discoverWhisperExecutable()
        whisperModelPath = defaults.string(forKey: "whisperModelPath")
            ?? Self.discoverWhisperModel()
        transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        microphoneDeviceID = defaults.string(forKey: "microphoneDeviceID") ?? ""
    }

    // MARK: - Methods

    /// Called by AppDelegate to inject the recording engine dependency.
    /// This pattern (dependency injection) makes testing easier.
    func setRecordingEngine(_ engine: any RecordingEngineProtocol) {
        recordingEngine = engine
    }

    func setTranscriptionRuntime(_ runtime: any TranscriptionRuntimeProtocol) {
        transcriptionRuntime = runtime
    }

    func updateTranscriptionStatus(_ snapshot: TranscriptionRuntime.Snapshot) {
        transcriptionSnapshot = snapshot
        if snapshot.state == .complete {
            userDefaults.removeObject(forKey: Self.activeTranscriptionBundlePathKey)
        }
    }

    func recoverTranscriptionSession() async {
        guard !isRecording,
              let bundlePath = userDefaults.string(
                forKey: Self.activeTranscriptionBundlePathKey
              ),
              !bundlePath.isEmpty else {
            return
        }
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            userDefaults.removeObject(forKey: Self.activeTranscriptionBundlePathKey)
            return
        }
        guard let transcriptionRuntime else { return }

        do {
            transcriptionConfigurationError = nil
            let snapshot = try await transcriptionRuntime.recoverSession(
                bundleURL: bundleURL,
                settings: try transcriptionSettings()
            )
            updateTranscriptionStatus(snapshot)
        } catch {
            transcriptionConfigurationError = error.localizedDescription
        }
    }

    func checkTranscriptionServer() async {
        guard !isRecording, let runtime = transcriptionRuntime else { return }
        do {
            transcriptionConfigurationError = nil
            try await runtime.checkServer(settings: try transcriptionSettings())
        } catch {
            transcriptionConfigurationError = error.localizedDescription
        }
    }

    /// Start recording to the given path, or auto-generate a timestamped filename.
    /// 'async throws' means this function is asynchronous and can fail with an error.
    func startRecording(outputPath: URL? = nil) async throws {
        // Guard statement: exit early if condition is false.
        // This is cleaner than nested if statements.
        guard !isRecording, !isStopping else { return }
        guard let engine = recordingEngine else {
            throw NSError(domain: "RecordingState", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recording engine not initialized"])
        }
        guard !transcriptionEnabled || transcriptionDisplayState != .draining else {
            throw TranscriptionConfigurationError.sessionDraining
        }

        // Use provided path or generate one with a timestamp.
        let path = outputPath ?? generateOutputPath()
        self.outputPath = path

        var transcriptionPipelines: SourceTranscriptionPipelines?
        if transcriptionEnabled, let runtime = transcriptionRuntime {
            do {
                transcriptionConfigurationError = nil
                var sources: Set<TranscriptionSource> = []
                if recordSystemAudio { sources.insert(.system) }
                if recordMicrophone { sources.insert(.microphone) }
                transcriptionPipelines = try await runtime.startSession(
                    recordingURL: path,
                    sources: sources,
                    settings: try transcriptionSettings()
                )
                sessionTranscriptionActive = true
                let snapshot = await runtime.snapshot()
                if let bundleURL = snapshot.bundleURL {
                    userDefaults.set(
                        bundleURL.path,
                        forKey: Self.activeTranscriptionBundlePathKey
                    )
                }
            } catch let error as TranscriptionRuntime.RuntimeError
                where error == .sessionAlreadyActive {
                transcriptionConfigurationError =
                    TranscriptionConfigurationError.sessionDraining.localizedDescription
                sessionTranscriptionActive = false
                throw TranscriptionConfigurationError.sessionDraining
            } catch {
                transcriptionConfigurationError = error.localizedDescription
                sessionTranscriptionActive = false
            }
        }

        do {
            activeMicrophoneName = try await engine.startRecording(
                to: path,
                recordSystemAudio: recordSystemAudio,
                recordMicrophone: recordMicrophone,
                microphoneDeviceID: microphoneDeviceID.isEmpty ? nil : microphoneDeviceID,
                duration: duration,
                transcriptionPipelines: transcriptionPipelines
            )
        } catch {
            if let transcriptionPipelines {
                try? await transcriptionPipelines.finish()
                await transcriptionRuntime?.finishSession()
                sessionTranscriptionActive = false
            }
            throw error
        }

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
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        // Invalidate (stop) the timer and release it.
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        await recordingEngine?.stopRecording()

        // The archival WAV is complete at this point. Publish that fact before
        // starting the potentially long transcript drain.
        isRecording = false
        activeMicrophoneName = nil
        systemAudioLevel = 0
        microphoneLevel = 0
        systemAudioPeak = 0
        microphonePeak = 0

        if sessionTranscriptionActive, let transcriptionRuntime {
            sessionTranscriptionActive = false
            let snapshot = await transcriptionRuntime.beginFinishingSession()
            updateTranscriptionStatus(snapshot)
        }
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

    var transcriptionDisplayState: TranscriptionRuntime.State {
        transcriptionConfigurationError == nil ? transcriptionSnapshot.state : .failed
    }

    var canStartRecording: Bool {
        !isRecording
            && !isStopping
            && (!transcriptionEnabled || transcriptionDisplayState != .draining)
    }

    var transcriptionError: String? {
        transcriptionConfigurationError ?? transcriptionSnapshot.error
    }

    func shutdownTranscription() async {
        await transcriptionRuntime?.shutdown()
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

    private func transcriptionSettings() throws -> TranscriptionRuntime.Settings {
        let executable = whisperExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = transcriptionLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            throw TranscriptionConfigurationError.missingExecutable
        }
        guard !model.isEmpty else {
            throw TranscriptionConfigurationError.missingModel
        }
        guard !language.isEmpty else {
            throw TranscriptionConfigurationError.missingLanguage
        }
        return .init(
            executableURL: URL(fileURLWithPath: NSString(string: executable).expandingTildeInPath),
            modelURL: URL(fileURLWithPath: NSString(string: model).expandingTildeInPath),
            requestedLanguage: language
        )
    }

    private static func discoverWhisperExecutable() -> String {
        if let configured = ProcessInfo.processInfo.environment["SONOTWIN_WHISPER_SERVER"],
           !configured.isEmpty {
            return configured
        }

        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { String($0) + "/whisper-server" }
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? ""
    }

    private static func discoverWhisperModel() -> String {
        if let configured = ProcessInfo.processInfo.environment["SONOTWIN_WHISPER_MODEL"],
           !configured.isEmpty {
            return configured
        }

        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        guard let directory = documents?.appendingPathComponent(
            "WhisperCppModels",
            isDirectory: true
        ), let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return ""
        }
        let models = entries.filter { $0.pathExtension.lowercased() == "bin" }
        return models.first {
            $0.lastPathComponent == "ggml-large-v3-turbo.bin"
        }?.path ?? models.first?.path ?? ""
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

private enum TranscriptionConfigurationError: Error, LocalizedError {
    case missingExecutable
    case missingModel
    case missingLanguage
    case sessionDraining

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Choose a whisper-server executable"
        case .missingModel:
            return "Choose a Whisper model"
        case .missingLanguage:
            return "Enter a language code or auto"
        case .sessionDraining:
            return "Previous transcript is still finishing"
        }
    }
}
