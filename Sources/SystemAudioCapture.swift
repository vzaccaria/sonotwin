import ScreenCaptureKit
import AVFoundation

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate {
    private var stream: SCStream?
    private var isRunning = false
    var onSamples: ((AVAudioPCMBuffer) -> Void)?

    private let sampleRate: Double
    private let channels: Int

    init(sampleRate: Double = 48000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCStream stopped with error: \(error)")
    }

    func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            print("Screen capture permission denied: \(error)")
            return false
        }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = channels
        config.excludesCurrentProcessAudio = true

        // Minimal video capture (required by SCK even for audio-only)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream = stream else {
            throw NSError(domain: "SystemAudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create SCStream"])
        }

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        isRunning = true
    }

    func stop() async {
        if isRunning, let stream = stream {
            try? await stream.stopCapture()
            isRunning = false
        }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        )!

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let channelCount = Int(format.channelCount)

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Non-interleaved
            for channel in 0..<channelCount {
                let channelData = pcmBuffer.floatChannelData![channel]
                let srcOffset = channel * Int(frameCount) * MemoryLayout<Float>.size
                memcpy(channelData, dataPointer.advanced(by: srcOffset), Int(frameCount) * MemoryLayout<Float>.size)
            }
        } else {
            // Interleaved - deinterleave
            let src = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                for channel in 0..<channelCount {
                    pcmBuffer.floatChannelData![channel][frame] = src[frame * channelCount + channel]
                }
            }
        }

        onSamples?(pcmBuffer)
    }
}
