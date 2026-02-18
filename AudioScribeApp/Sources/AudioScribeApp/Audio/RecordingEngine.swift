import Foundation
import AVFoundation

/// Orchestrates audio capture, mixing, and writing
final class RecordingEngine: @unchecked Sendable {
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var mixer: AudioMixer?
    private var writer: WAVWriter?

    private let systemMeter = LevelMeter()
    private let micMeter = LevelMeter()

    private var isRecording = false
    private var levelUpdateCallback: ((Float, Float, Float, Float) -> Void)?
    private var levelUpdateTimer: Timer?

    private var recordingSystemAudio = false
    private var recordingMicrophone = false

    private let lock = NSLock()

    /// Set callback for level updates (called on main thread)
    func setLevelUpdateCallback(_ callback: @escaping (Float, Float, Float, Float) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.levelUpdateCallback = callback
    }

    /// Start recording with specified sources
    func startRecording(
        to outputPath: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        duration: TimeInterval?
    ) async throws {
        lock.lock()
        guard !isRecording else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Create WAV writer
        let newWriter = try WAVWriter(outputPath: outputPath)

        lock.lock()
        self.writer = newWriter
        self.recordingSystemAudio = recordSystemAudio
        self.recordingMicrophone = recordMicrophone
        lock.unlock()

        // Determine if we need mixing
        let needsMixing = recordSystemAudio && recordMicrophone

        if needsMixing {
            // Create mixer for combined mode
            let newMixer = AudioMixer(writer: newWriter)
            lock.lock()
            self.mixer = newMixer
            lock.unlock()

            // Setup system audio capture
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                self?.handleSystemSamples(buffer, mixing: true)
            }

            // Setup microphone capture
            let micCap = MicrophoneCapture()
            micCap.onSamples = { [weak self] buffer in
                self?.handleMicSamples(buffer, mixing: true)
            }

            lock.lock()
            self.systemCapture = sysCapture
            self.micCapture = micCap
            lock.unlock()

            // Start both captures
            try await sysCapture.start()
            try micCap.start()
        } else if recordSystemAudio {
            // System audio only
            let sysCapture = SystemAudioCapture()
            sysCapture.onSamples = { [weak self] buffer in
                self?.handleSystemSamples(buffer, mixing: false)
            }
            lock.lock()
            self.systemCapture = sysCapture
            lock.unlock()
            try await sysCapture.start()
        } else if recordMicrophone {
            // Microphone only
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

        // Start level update timer on main thread
        await MainActor.run {
            self.startLevelUpdates()
        }
    }

    /// Stop recording and finalize output file
    func stopRecording() async {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        lock.unlock()

        await MainActor.run {
            self.stopLevelUpdates()
        }

        // Stop captures
        lock.lock()
        let sysCapture = systemCapture
        let micCap = micCapture
        let mixerRef = mixer
        let writerRef = writer
        lock.unlock()

        if let sysCapture = sysCapture {
            await sysCapture.stop()
        }
        micCap?.stop()

        // Flush mixer if used
        mixerRef?.flush()

        // Finalize WAV file
        try? writerRef?.finalize()

        // Reset state
        lock.lock()
        systemCapture = nil
        micCapture = nil
        mixer = nil
        writer = nil
        isRecording = false
        recordingSystemAudio = false
        recordingMicrophone = false
        lock.unlock()

        systemMeter.reset()
        micMeter.reset()
    }

    // MARK: - Private Methods

    private func handleSystemSamples(_ buffer: AVAudioPCMBuffer, mixing: Bool) {
        systemMeter.process(buffer)

        lock.lock()
        let mixerRef = mixer
        let writerRef = writer
        lock.unlock()

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

    @MainActor
    private func startLevelUpdates() {
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.sendLevelUpdate()
        }
    }

    @MainActor
    private func stopLevelUpdates() {
        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }

    private func sendLevelUpdate() {
        lock.lock()
        let sysRMS = recordingSystemAudio ? systemMeter.rmsLevel : 0
        let sysPeak = recordingSystemAudio ? systemMeter.peakLevel : 0
        let micRMS = recordingMicrophone ? micMeter.rmsLevel : 0
        let micPeak = recordingMicrophone ? micMeter.peakLevel : 0
        let callback = levelUpdateCallback
        lock.unlock()

        DispatchQueue.main.async {
            callback?(sysRMS, sysPeak, micRMS, micPeak)
        }
    }
}
