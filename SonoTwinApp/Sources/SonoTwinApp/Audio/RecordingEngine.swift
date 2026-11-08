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
// Using 'actor' provides automatic thread safety for all properties.
// Swift ensures only one task can access actor state at a time,
// eliminating the need for manual locking (NSLock).

actor RecordingEngine {

    // MARK: - Audio Pipeline Components
    // These are optional because they're created when recording starts
    // and destroyed when recording stops.

    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var mixer: AudioMixer?
    private var writer: WAVWriter?
    private var sourceTranscriptionPipelines: SourceTranscriptionPipelines?

    // MARK: - Level Meters
    // One for each audio source. These calculate RMS/peak for VU meters.

    private let systemMeter = LevelMeter()
    private let micMeter = LevelMeter()

    // MARK: - State
    private var isRecording = false
    private var levelUpdateCallback: (@Sendable (Float, Float, Float, Float) -> Void)?
    private var recordingStartUptimeNanoseconds: UInt64?

    private var recordingSystemAudio = false
    private var recordingMicrophone = false

    // MARK: - Configuration

    /// Set callback for level updates (called at ~30fps).
    /// Parameters are: systemRMS, systemPeak, micRMS, micPeak (all 0.0-1.0).
    /// The callback must be @Sendable since it's called from actor context.
    func setLevelUpdateCallback(_ callback: @escaping @Sendable (Float, Float, Float, Float) -> Void) {
        self.levelUpdateCallback = callback
    }

    // MARK: - Recording Control

    /// Start recording with specified sources.
    /// - Parameters:
    ///   - outputPath: Where to save the .wav file
    ///   - recordSystemAudio: Whether to capture system audio
    ///   - recordMicrophone: Whether to capture microphone
    ///   - microphoneDeviceID: Input device to capture (nil = system default)
    ///   - duration: Optional auto-stop duration (nil = manual stop)
    /// - Returns: Name of the microphone actually captured, nil when not recording it
    @discardableResult
    func startRecording(
        to outputPath: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        microphoneDeviceID: String?,
        duration: TimeInterval?,
        transcriptionPipelines: SourceTranscriptionPipelines?
    ) async throws -> String? {
        guard !isRecording else { return nil }

        let newWriter = try WAVWriter(outputPath: outputPath)
        self.writer = newWriter
        self.sourceTranscriptionPipelines = transcriptionPipelines
        self.recordingStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.recordingSystemAudio = recordSystemAudio
        self.recordingMicrophone = recordMicrophone

        // MARK: Setup Audio Pipeline
        // The pipeline depends on which sources are selected.
        let needsMixing = recordSystemAudio && recordMicrophone
        var microphoneName: String?

        if needsMixing {
            // MARK: Combined Mode (System + Mic)
            // Create a mixer to combine both streams.
            let newMixer = AudioMixer(writer: newWriter)
            self.mixer = newMixer

            // Setup system audio capture with callback.
            // [weak self] prevents retain cycles.
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                let capturedAt = DispatchTime.now().uptimeNanoseconds
                Task { [weak self] in
                    await self?.handleSystemSamples(
                        buffer,
                        mixing: true,
                        capturedAtNanoseconds: capturedAt
                    )
                }
            }

            // Setup microphone capture.
            let micCap = MicrophoneCapture(deviceID: microphoneDeviceID)
            micCap.onSamples = { [weak self] buffer in
                let capturedAt = DispatchTime.now().uptimeNanoseconds
                Task { [weak self] in
                    await self?.handleMicSamples(
                        buffer,
                        mixing: true,
                        capturedAtNanoseconds: capturedAt
                    )
                }
            }

            self.systemCapture = sysCapture
            self.micCapture = micCap

            // Start both captures.
            try await sysCapture.start()
            microphoneName = try micCap.start()

        } else if recordSystemAudio {
            // MARK: System Audio Only
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                let capturedAt = DispatchTime.now().uptimeNanoseconds
                Task { [weak self] in
                    await self?.handleSystemSamples(
                        buffer,
                        mixing: false,
                        capturedAtNanoseconds: capturedAt
                    )
                }
            }
            self.systemCapture = sysCapture
            try await sysCapture.start()

        } else if recordMicrophone {
            // MARK: Microphone Only
            let micCap = MicrophoneCapture(deviceID: microphoneDeviceID)
            micCap.onSamples = { [weak self] buffer in
                let capturedAt = DispatchTime.now().uptimeNanoseconds
                Task { [weak self] in
                    await self?.handleMicSamples(
                        buffer,
                        mixing: false,
                        capturedAtNanoseconds: capturedAt
                    )
                }
            }
            self.micCapture = micCap
            microphoneName = try micCap.start()
        }

        isRecording = true

        // MARK: Start Level Updates
        // Start a detached task that periodically sends level updates.
        Task { [weak self] in
            await self?.levelUpdateLoop()
        }
        return microphoneName
    }

    /// Stop recording and finalize output file.
    func stopRecording() async {
        guard isRecording else { return }

        // Mark as not recording first to stop the level update loop.
        isRecording = false

        // Stop captures.
        if let sysCapture = systemCapture {
            await sysCapture.stop()
        }
        micCapture?.stop()

        // Flush any remaining buffered audio.
        // This is critical - without it, the last samples are lost!
        mixer?.flush()

        // Finalize the WAV file (updates header with actual size).
        try? writer?.finalize()

        if let sourceTranscriptionPipelines {
            do {
                try await sourceTranscriptionPipelines.finish()
            } catch {
                print("Error finalizing transcription chunks: \(error)")
            }
        }

        // Reset state for next recording.
        systemCapture = nil
        micCapture = nil
        mixer = nil
        writer = nil
        sourceTranscriptionPipelines = nil
        recordingSystemAudio = false
        recordingMicrophone = false
        recordingStartUptimeNanoseconds = nil

        // Reset meters to zero.
        systemMeter.reset()
        micMeter.reset()
    }

    // MARK: - Audio Sample Handlers
    // Called from audio capture callbacks via Task.

    private func handleSystemSamples(
        _ buffer: AVAudioPCMBuffer,
        mixing: Bool,
        capturedAtNanoseconds: UInt64
    ) {
        systemMeter.process(buffer)
        let transcriptionSamples = routeToTranscription(
            buffer,
            source: .system,
            capturedAtNanoseconds: capturedAtNanoseconds
        )

        if mixing {
            mixer?.addSystemAudio(buffer)
        } else if let transcriptionSamples {
            writer?.appendSamples(transcriptionSamples)
        } else {
            writer?.appendSamples(buffer)
        }
    }

    private func handleMicSamples(
        _ buffer: AVAudioPCMBuffer,
        mixing: Bool,
        capturedAtNanoseconds: UInt64
    ) {
        micMeter.process(buffer)
        let transcriptionSamples = routeToTranscription(
            buffer,
            source: .microphone,
            capturedAtNanoseconds: capturedAtNanoseconds
        )

        if mixing {
            mixer?.addMicAudio(buffer)
        } else if let transcriptionSamples {
            writer?.appendSamples(transcriptionSamples)
        } else {
            writer?.appendSamples(buffer)
        }
    }

    private func routeToTranscription(
        _ buffer: AVAudioPCMBuffer,
        source: TranscriptionSource,
        capturedAtNanoseconds: UInt64
    ) -> Data? {
        guard let pipelines = sourceTranscriptionPipelines,
              pipelines.contains(source),
              let samples = WAVWriter.pcm16Data(from: buffer) else {
            return nil
        }

        let firstSampleMilliseconds = firstSampleMilliseconds(
            for: buffer,
            capturedAtNanoseconds: capturedAtNanoseconds
        )
        _ = pipelines.append(
            samples,
            source: source,
            firstSampleMilliseconds: firstSampleMilliseconds
        )
        return samples
    }

    private func firstSampleMilliseconds(
        for buffer: AVAudioPCMBuffer,
        capturedAtNanoseconds: UInt64
    ) -> Int64 {
        guard let recordingStartUptimeNanoseconds,
              buffer.format.sampleRate > 0 else {
            return 0
        }

        let elapsedNanoseconds = capturedAtNanoseconds >= recordingStartUptimeNanoseconds
            ? capturedAtNanoseconds - recordingStartUptimeNanoseconds
            : 0
        let bufferNanoseconds = UInt64(
            Double(buffer.frameLength) * 1_000_000_000 / buffer.format.sampleRate
        )
        let firstSampleNanoseconds = elapsedNanoseconds > bufferNanoseconds
            ? elapsedNanoseconds - bufferNanoseconds
            : 0
        return Int64(firstSampleNanoseconds / 1_000_000)
    }

    // MARK: - Level Update Loop
    // Runs while recording, sending level updates at ~30fps.

    private func levelUpdateLoop() async {
        while isRecording {
            // Get current levels from meters.
            let sysRMS = recordingSystemAudio ? systemMeter.rmsLevel : 0
            let sysPeak = recordingSystemAudio ? systemMeter.peakLevel : 0
            let micRMS = recordingMicrophone ? micMeter.rmsLevel : 0
            let micPeak = recordingMicrophone ? micMeter.peakLevel : 0

            // Send to callback on main thread for UI updates.
            if let callback = levelUpdateCallback {
                await MainActor.run {
                    callback(sysRMS, sysPeak, micRMS, micPeak)
                }
            }

            // Wait ~33ms (30fps). Use Task.sleep for async-friendly sleeping.
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }
}
