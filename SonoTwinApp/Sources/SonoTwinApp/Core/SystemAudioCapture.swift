import ScreenCaptureKit
import AVFoundation
import CoreGraphics

// MARK: - SystemAudioCapture
// Captures system audio (audio from other apps) using ScreenCaptureKit.
//
// ScreenCaptureKit (macOS 12.3+) is Apple's modern API for screen/audio capture.
// Ironically, to capture audio, you need screen recording permission because
// SCK was designed for screen recording with audio.
//
// @unchecked Sendable: We manually ensure thread safety. Audio callbacks
// come from ScreenCaptureKit's internal threads.
//
// NSObject: Required base class for Objective-C interoperability.
// SCStreamDelegate: Protocol to receive stream events (errors, etc.).

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate {

    // MARK: - Properties

    /// The ScreenCaptureKit stream (nil until start() is called).
    private var stream: SCStream?

    /// Whether the stream is currently running.
    private var isRunning = false

    /// Callback invoked when audio samples are available.
    /// AVAudioPCMBuffer contains the audio data in a format ready for processing.
    var onSamples: ((AVAudioPCMBuffer) -> Void)?

    /// Audio configuration.
    private let sampleRate: Double
    private let channels: Int

    // MARK: - Initialization

    init(sampleRate: Double = 48000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        super.init()  // NSObject requires super.init()
    }

    // MARK: - SCStreamDelegate

    /// Called when the stream stops due to an error.
    /// This is a delegate method - ScreenCaptureKit calls this.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCStream stopped with error: \(error)")
    }

    // MARK: - Permission Handling

    /// Check if we have screen recording permission.
    func hasPermission() -> Bool {
        // CGPreflightScreenCaptureAccess checks without prompting.
        return CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission.
    /// Returns true if permission is granted.
    func requestPermission() async -> Bool {
        // Try to request via CoreGraphics (may show a prompt).
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // Verify with ScreenCaptureKit by trying to get shareable content.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Capture Control

    /// Start capturing system audio.
    /// 'async throws' because this involves async API calls that can fail.
    func start() async throws {
        // MARK: Get Shareable Content
        // SCShareableContent lists what can be captured (displays, windows, apps).
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // We need at least one display to create a capture filter.
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        // MARK: Create Content Filter
        // SCContentFilter specifies what to capture.
        // We want the entire display but we're only interested in audio.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // MARK: Configure Stream
        let config = SCStreamConfiguration()
        config.capturesAudio = true  // We want audio!
        config.sampleRate = Int(sampleRate)
        config.channelCount = channels
        config.excludesCurrentProcessAudio = true  // Don't capture our own output

        // Minimal video configuration (SCK requires video, but we minimize it).
        // Using 1x1 causes errors, so we use 2x2 as the minimum.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // MARK: Create and Start Stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream = stream else {
            throw NSError(domain: "SystemAudioCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create SCStream"])
        }

        // Add ourselves as the audio output handler.
        // .userInitiated QoS ensures timely processing.
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start the capture (async operation).
        try await stream.startCapture()
        isRunning = true
    }

    /// Stop capturing.
    func stop() async {
        if isRunning, let stream = stream {
            try? await stream.stopCapture()
            isRunning = false
        }
    }
}

// MARK: - SCStreamOutput
// This extension implements the audio sample handler.
// SCStreamOutput is the protocol for receiving captured data.

extension SystemAudioCapture: SCStreamOutput {

    /// Called by ScreenCaptureKit when audio (or video) data is available.
    /// This runs on the queue we specified in addStreamOutput().
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Ignore video frames - we only want audio.
        guard type == .audio else { return }

        // MARK: Get Audio Format
        // CMSampleBuffer contains the raw audio data plus format information.
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Create an AVAudioFormat from the stream's format description.
        // This tells us sample rate, channel count, and data format.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false  // Non-interleaved = separate array per channel
        )!

        // MARK: Extract Audio Data
        // CMSampleBuffer stores data in a CMBlockBuffer.
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer else { return }

        // MARK: Create PCM Buffer
        // AVAudioPCMBuffer is the standard format for processing audio in AVFoundation.
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let channelCount = Int(format.channelCount)

        // MARK: Copy Data to PCM Buffer
        // Handle both interleaved and non-interleaved formats.
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Non-interleaved: each channel's samples are contiguous.
            // [L0,L1,L2,...,R0,R1,R2,...]
            for channel in 0..<channelCount {
                let channelData = pcmBuffer.floatChannelData![channel]
                let srcOffset = channel * Int(frameCount) * MemoryLayout<Float>.size
                memcpy(channelData, dataPointer.advanced(by: srcOffset),
                       Int(frameCount) * MemoryLayout<Float>.size)
            }
        } else {
            // Interleaved: samples alternate between channels.
            // [L0,R0,L1,R1,L2,R2,...]
            let src = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                for channel in 0..<channelCount {
                    pcmBuffer.floatChannelData![channel][frame] = src[frame * channelCount + channel]
                }
            }
        }

        // MARK: Deliver to Callback
        // The callback processes the audio (metering, mixing, writing).
        onSamples?(pcmBuffer)
    }
}
