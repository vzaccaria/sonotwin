import Foundation
import AVFoundation

// MARK: - Recording Engine
// Orchestrates the audio capture, mixing, and writing pipeline.
//
// This class coordinates multiple components:
// - SystemAudioCapture: Gets audio from apps (via ScreenCaptureKit)
// - MicrophoneCapture: Gets audio from the microphone
// - AudioMixer: Combines two audio streams into one
// - WAVWriter: Writes audio data to a .wav file
// - LevelMeter: Calculates audio levels for VU meters
//
// @unchecked Sendable: We manually ensure thread safety using NSLock.
// Without @unchecked, Swift would require all properties to be Sendable.

final class RecordingEngine: @unchecked Sendable {

    // MARK: - Audio Pipeline Components
    // These are optional because they're created when recording starts
    // and destroyed when recording stops.

    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var mixer: AudioMixer?
    private var writer: WAVWriter?

    // MARK: - Level Meters
    // One for each audio source. These calculate RMS/peak for VU meters.
    // 'let' means these are constants - created once and never replaced.

    private let systemMeter = LevelMeter()
    private let micMeter = LevelMeter()

    // MARK: - State
    private var isRecording = false
    private var levelUpdateCallback: ((Float, Float, Float, Float) -> Void)?
    private var levelUpdateTimer: Timer?

    private var recordingSystemAudio = false
    private var recordingMicrophone = false

    // MARK: - Thread Safety
    // NSLock provides mutual exclusion for accessing shared state.
    // Audio callbacks come from different threads, so we need synchronization.

    private let lock = NSLock()

    // MARK: - Configuration

    /// Set callback for level updates (called on main thread at ~30fps).
    /// Parameters are: systemRMS, systemPeak, micRMS, micPeak (all 0.0-1.0).
    func setLevelUpdateCallback(_ callback: @escaping (Float, Float, Float, Float) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.levelUpdateCallback = callback
    }

    // MARK: - Recording Control

    /// Start recording with specified sources.
    /// - Parameters:
    ///   - outputPath: Where to save the .wav file
    ///   - recordSystemAudio: Whether to capture system audio
    ///   - recordMicrophone: Whether to capture microphone
    ///   - duration: Optional auto-stop duration (nil = manual stop)
    func startRecording(
        to outputPath: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        duration: TimeInterval?
    ) async throws {
        // Check if already recording (with thread safety).
        lock.lock()
        guard !isRecording else {
            lock.unlock()
            return
        }
        lock.unlock()

        // MARK: Create WAV Writer
        // This opens the output file and writes the WAV header.
        let newWriter = try WAVWriter(outputPath: outputPath)

        lock.lock()
        self.writer = newWriter
        self.recordingSystemAudio = recordSystemAudio
        self.recordingMicrophone = recordMicrophone
        lock.unlock()

        // MARK: Setup Audio Pipeline
        // The pipeline depends on which sources are selected.
        let needsMixing = recordSystemAudio && recordMicrophone

        if needsMixing {
            // MARK: Combined Mode (System + Mic)
            // Create a mixer to combine both streams.
            let newMixer = AudioMixer(writer: newWriter)

            lock.lock()
            self.mixer = newMixer
            lock.unlock()

            // Setup system audio capture with callback.
            // [weak self] prevents retain cycles - the closure doesn't keep 'self' alive.
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                self?.handleSystemSamples(buffer, mixing: true)
            }

            // Setup microphone capture.
            let micCap = MicrophoneCapture()
            micCap.onSamples = { [weak self] buffer in
                self?.handleMicSamples(buffer, mixing: true)
            }

            lock.lock()
            self.systemCapture = sysCapture
            self.micCapture = micCap
            lock.unlock()

            // Start both captures.
            // 'try await' for async operations that can fail.
            try await sysCapture.start()
            try micCap.start()

        } else if recordSystemAudio {
            // MARK: System Audio Only
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                self?.handleSystemSamples(buffer, mixing: false)
            }

            lock.lock()
            self.systemCapture = sysCapture
            lock.unlock()

            try await sysCapture.start()

        } else if recordMicrophone {
            // MARK: Microphone Only
            let micCap = MicrophoneCapture()
            micCap.onSamples = { [weak self] buffer in
                self?.handleMicSamples(buffer, mixing: false)
            }

            lock.lock()
            self.micCapture = micCap
            lock.unlock()

            try micCap.start()
        }

        lock.lock()
        isRecording = true
        lock.unlock()

        // MARK: Start Level Updates
        // Timer must be scheduled on the main thread for UI updates.
        await MainActor.run {
            self.startLevelUpdates()
        }
    }

    /// Stop recording and finalize output file.
    func stopRecording() async {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Stop the level update timer.
        await MainActor.run {
            self.stopLevelUpdates()
        }

        // Get references to components (with lock) before stopping them.
        lock.lock()
        let sysCapture = systemCapture
        let micCap = micCapture
        let mixerRef = mixer
        let writerRef = writer
        lock.unlock()

        // Stop captures.
        if let sysCapture = sysCapture {
            await sysCapture.stop()
        }
        micCap?.stop()

        // Flush any remaining buffered audio.
        // This is critical - without it, the last few samples are lost!
        mixerRef?.flush()

        // Finalize the WAV file (updates header with actual size).
        try? writerRef?.finalize()

        // Reset state for next recording.
        lock.lock()
        systemCapture = nil
        micCapture = nil
        mixer = nil
        writer = nil
        isRecording = false
        recordingSystemAudio = false
        recordingMicrophone = false
        lock.unlock()

        // Reset meters to zero.
        systemMeter.reset()
        micMeter.reset()
    }

    // MARK: - Audio Sample Handlers
    // These are called from audio capture callbacks (potentially on background threads).

    private func handleSystemSamples(_ buffer: AVAudioPCMBuffer, mixing: Bool) {
        // Update level meter for VU display.
        systemMeter.process(buffer)

        // Get references with lock.
        lock.lock()
        let mixerRef = mixer
        let writerRef = writer
        lock.unlock()

        // Route audio to mixer or directly to writer.
        if mixing {
            mixerRef?.addSystemAudio(buffer)
        } else {
            writerRef?.appendSamples(buffer)
        }
    }

    private func handleMicSamples(_ buffer: AVAudioPCMBuffer, mixing: Bool) {
        micMeter.process(buffer)

        lock.lock()
        let mixerRef = mixer
        let writerRef = writer
        lock.unlock()

        if mixing {
            mixerRef?.addMicAudio(buffer)
        } else {
            writerRef?.appendSamples(buffer)
        }
    }

    // MARK: - Level Update Timer
    // Updates UI at ~30fps with current audio levels.

    @MainActor
    private func startLevelUpdates() {
        // Timer fires every 1/30 second (~33ms).
        // [weak self] prevents the timer from keeping this object alive.
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.sendLevelUpdate()
        }
    }

    @MainActor
    private func stopLevelUpdates() {
        // Invalidate stops the timer and removes it from the run loop.
        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }

    private func sendLevelUpdate() {
        // Read current levels from meters.
        lock.lock()
        let sysRMS = recordingSystemAudio ? systemMeter.rmsLevel : 0
        let sysPeak = recordingSystemAudio ? systemMeter.peakLevel : 0
        let micRMS = recordingMicrophone ? micMeter.rmsLevel : 0
        let micPeak = recordingMicrophone ? micMeter.peakLevel : 0
        let callback = levelUpdateCallback
        lock.unlock()

        // Call the callback on the main thread (for UI updates).
        DispatchQueue.main.async {
            callback?(sysRMS, sysPeak, micRMS, micPeak)
        }
    }
}
