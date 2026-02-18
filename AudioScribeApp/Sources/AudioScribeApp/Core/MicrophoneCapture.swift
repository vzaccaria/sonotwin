import AVFoundation
import CoreMedia

final class MicrophoneCapture: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var isRunning = false
    var onSamples: ((AVAudioPCMBuffer) -> Void)?

    private let outputFormat: AVAudioFormat
    private let sampleRate: Double
    private let channels: UInt32
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        super.init()
    }

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func hasPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func permissionStatus() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func start() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        // Get default audio device
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "MicrophoneCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device available"])
        }

        // Add input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            throw NSError(domain: "MicrophoneCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
        }
        session.addInput(audioInput)

        // Add output
        let audioOutput = AVCaptureAudioDataOutput()
        let queue = DispatchQueue(label: "com.audioscribe.mic", qos: .userInteractive)
        audioOutput.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(audioOutput) else {
            throw NSError(domain: "MicrophoneCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
        }
        session.addOutput(audioOutput)

        session.commitConfiguration()
        session.startRunning()

        captureSession = session
        isRunning = true
    }

    func stop() {
        if isRunning, let session = captureSession {
            session.stopRunning()
            captureSession = nil
            isRunning = false
        }
    }

    // AVCaptureAudioDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Setup converter on first sample if needed
        if converter == nil {
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.pointee.mSampleRate,
                channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
                interleaved: true
            )!
            inputFormat = srcFormat
            converter = AVAudioConverter(from: srcFormat, to: outputFormat)
        }

        guard let converter = converter, let inputFormat = inputFormat else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else { return }

        let inputFrameCount = AVAudioFrameCount(sampleBuffer.numSamples)

        // Create input buffer
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else { return }
        inputBuffer.frameLength = inputFrameCount

        // Copy data to input buffer
        let src = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        let inputChannels = Int(inputFormat.channelCount)
        for frame in 0..<Int(inputFrameCount) {
            for ch in 0..<inputChannels {
                inputBuffer.floatChannelData![ch][frame] = src[frame * inputChannels + ch]
            }
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil else { return }

        onSamples?(outputBuffer)
    }
}
