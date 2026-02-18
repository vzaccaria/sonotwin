import AVFoundation
import Accelerate

/// Calculates audio levels (RMS and peak) using Accelerate framework
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var currentRMS: Float = 0.0
    private var currentPeak: Float = 0.0
    private let smoothingFactor: Float = 0.3

    /// Minimum dB value for display (-60 dB is typically silence)
    static let minDB: Float = -60.0
    /// Maximum dB value for display
    static let maxDB: Float = 0.0

    /// Process audio buffer and update levels
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        var maxRMS: Float = 0.0
        var maxPeak: Float = 0.0

        for channel in 0..<channelCount {
            let samples = channelData[channel]

            // Calculate RMS using vDSP_rmsqv (root mean square)
            var rms: Float = 0.0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))

            // Calculate peak using vDSP_maxmgv (maximum magnitude)
            var peak: Float = 0.0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount))

            maxRMS = max(maxRMS, rms)
            maxPeak = max(maxPeak, peak)
        }

        lock.lock()
        // Apply smoothing for stable display
        currentRMS = currentRMS * (1.0 - smoothingFactor) + maxRMS * smoothingFactor
        currentPeak = max(currentPeak * 0.95, maxPeak) // Peak hold with decay
        lock.unlock()
    }

    /// Get current RMS level as normalized value (0.0 to 1.0)
    var rmsLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentRMS
    }

    /// Get current peak level as normalized value (0.0 to 1.0)
    var peakLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return min(currentPeak, 1.0)
    }

    /// Get current RMS level in dB (-60 to 0)
    var rmsDB: Float {
        let level = rmsLevel
        guard level > 0 else { return Self.minDB }
        return max(Self.minDB, 20.0 * log10(level))
    }

    /// Get current peak level in dB (-60 to 0)
    var peakDB: Float {
        let level = peakLevel
        guard level > 0 else { return Self.minDB }
        return max(Self.minDB, 20.0 * log10(level))
    }

    /// Convert dB value to normalized 0-1 range for UI display
    static func dbToNormalized(_ db: Float) -> Float {
        let clamped = max(minDB, min(maxDB, db))
        return (clamped - minDB) / (maxDB - minDB)
    }

    /// Reset levels to zero
    func reset() {
        lock.lock()
        currentRMS = 0.0
        currentPeak = 0.0
        lock.unlock()
    }
}
