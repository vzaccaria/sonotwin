import AVFoundation
import CoreMedia

// MARK: - MicrophoneCapture
// Captures audio from the microphone using AVCaptureSession.
//
// Why AVCaptureSession instead of AVAudioEngine?
// AVAudioEngine's installTap() doesn't work when the app is launched via `open`
// (which is required for microphone permission prompts). AVCaptureSession works
// in both direct and `open` launch scenarios.
//
// This class also resamples audio to a consistent sample rate (48kHz).
// Different microphones use different rates (e.g., AirPods use 24kHz).
//
// @unchecked Sendable: Audio callbacks come from AVCaptureSession's threads.
// NSObject: Required for AVCaptureAudioDataOutputSampleBufferDelegate.

final class MicrophoneCapture: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Properties

    /// The capture session manages input/output connections.
    private var captureSession: AVCaptureSession?

    /// Whether we're currently capturing.
    private var isRunning = false

    /// Callback for delivering audio samples.
    var onSamples: ((AVAudioPCMBuffer) -> Void)?

    /// Target output format (consistent sample rate and channels).
    private let outputFormat: AVAudioFormat
    private let sampleRate: Double
    private let channels: UInt32

    /// Audio converter for resampling.
    /// Created lazily when we know the input format.
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    // MARK: - Initialization

    init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        // standardFormatWithSampleRate creates a standard float32 non-interleaved format.
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        super.init()
    }

    // MARK: - Permission Handling

    /// Check current microphone permission status.
    func hasPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Get the detailed permission status.
    func permissionStatus() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request microphone permission.
    /// Returns true if granted.
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            // This triggers the permission dialog and waits for user response.
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Capture Control

    /// Start capturing from the microphone.
    /// 'throws' because device access can fail.
    func start() throws {
        // MARK: Create Capture Session
        let session = AVCaptureSession()
        session.beginConfiguration()  // Batch configuration changes

        // MARK: Add Audio Input
        // Get the default audio device (usually the system's selected mic).
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "MicrophoneCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio device available"])
        }

        // Create an input from the device.
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)

        // Check if we can add it to the session.
        guard session.canAddInput(audioInput) else {
            throw NSError(domain: "MicrophoneCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
        }
        session.addInput(audioInput)

        // MARK: Add Audio Output
        let audioOutput = AVCaptureAudioDataOutput()

        // Create a dedicated queue for audio processing.
        // .userInteractive QoS for low-latency audio handling.
        let queue = DispatchQueue(label: "com.audioscribe.mic", qos: .userInteractive)

        // Set ourselves as the delegate to receive audio samples.
        audioOutput.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(audioOutput) else {
            throw NSError(domain: "MicrophoneCapture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
        }
        session.addOutput(audioOutput)

        // Apply the configuration.
        session.commitConfiguration()

        // Start the capture session.
        session.startRunning()

        captureSession = session
        isRunning = true
    }

    /// Stop capturing.
    func stop() {
        if isRunning, let session = captureSession {
            session.stopRunning()
            captureSession = nil
            isRunning = false
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    /// Called by AVCaptureSession when audio samples are available.
    /// This runs on our dedicated queue.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        // MARK: Get Input Format
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // MARK: Setup Converter (Lazy)
        // Create the converter on first sample when we know the input format.
        if converter == nil {
            // Input format from the microphone (may be different sample rate).
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.pointee.mSampleRate,
                channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
                interleaved: true  // Mic output is typically interleaved
            )!
            inputFormat = srcFormat

            // AVAudioConverter handles sample rate and format conversion.
            converter = AVAudioConverter(from: srcFormat, to: outputFormat)
        }

        guard let converter = converter, let inputFormat = inputFormat else { return }

        // MARK: Extract Audio Data
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else { return }

        let inputFrameCount = AVAudioFrameCount(sampleBuffer.numSamples)

        // MARK: Create Input Buffer
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else { return }
        inputBuffer.frameLength = inputFrameCount

        // Copy interleaved data to non-interleaved buffer.
        let src = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        let inputChannels = Int(inputFormat.channelCount)
        for frame in 0..<Int(inputFrameCount) {
            for ch in 0..<inputChannels {
                inputBuffer.floatChannelData![ch][frame] = src[frame * inputChannels + ch]
            }
        }

        // MARK: Resample
        // Calculate output frame count based on sample rate ratio.
        // If input is 24kHz and output is 48kHz, we get 2x as many output frames.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return }

        // AVAudioConverter.convert() does the actual resampling.
        var error: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            // This closure is called to provide input to the converter.
            if inputConsumed {
                outStatus.pointee = .noDataNow  // No more input
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil else { return }

        // MARK: Deliver to Callback
        onSamples?(outputBuffer)
    }
}
