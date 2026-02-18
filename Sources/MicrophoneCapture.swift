import AVFoundation
import AVFAudio

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunning = false
    var onSamples: ((AVAudioPCMBuffer) -> Void)?

    private let outputFormat: AVAudioFormat

    init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
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

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "MicrophoneCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "MicrophoneCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }


        var tapCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            tapCount += 1


            // Convert to non-interleaved float format (mono->stereo)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: buffer.frameCapacity) else {
                return
            }

            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else {
                if tapCount <= 5 {
                    print("Conversion error: \(error?.localizedDescription ?? "unknown")")
                }
                return
            }

            self.onSamples?(convertedBuffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
    }
}
