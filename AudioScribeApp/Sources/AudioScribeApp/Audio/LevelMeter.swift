import AVFoundation
import Accelerate

// MARK: - LevelMeter
// Calculates audio levels (RMS and peak) from audio buffers.
// Uses Apple's Accelerate framework for SIMD-optimized math operations.
//
// Why Accelerate? Processing thousands of audio samples per buffer with a
// simple for-loop is slow. Accelerate uses CPU vector instructions (SIMD)
// to process multiple samples in parallel, making it much faster.
//
// @unchecked Sendable: Tells Swift's concurrency checker that we've manually
// verified this class is safe to use across threads (via NSLock).

final class LevelMeter: @unchecked Sendable {

    // MARK: - Thread Safety
    // NSLock provides mutual exclusion - only one thread can hold the lock at a time.
    // This prevents race conditions when audio callbacks update levels
    // while the UI reads them.

    private let lock = NSLock()

    // MARK: - Current Levels
    // These are updated by process() and read by the UI.
    // The smoothing creates a more pleasant meter movement.

    private var currentRMS: Float = 0.0
    private var currentPeak: Float = 0.0

    /// Smoothing factor (0-1). Higher = faster response, lower = smoother.
    /// 0.3 gives a nice balance between responsiveness and stability.
    private let smoothingFactor: Float = 0.3

    // MARK: - dB Scale Constants
    // Audio levels are typically displayed in decibels (dB).
    // 0 dB = full scale (maximum), -60 dB = effectively silence.
    // static means these belong to the type, not instances.

    static let minDB: Float = -60.0
    static let maxDB: Float = 0.0

    // MARK: - Process Audio Buffer
    /// Analyze an audio buffer and update RMS/peak levels.
    /// Called from audio callbacks, potentially on background threads.

    func process(_ buffer: AVAudioPCMBuffer) {
        // floatChannelData is an array of pointers to each channel's samples.
        // guard let safely unwraps the optional - if nil, we return early.
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        var maxRMS: Float = 0.0
        var maxPeak: Float = 0.0

        // Process each channel and take the maximum.
        for channel in 0..<channelCount {
            let samples = channelData[channel]

            // MARK: Calculate RMS using vDSP
            // RMS (Root Mean Square) represents the "average" signal level.
            // vDSP_rmsqv computes: sqrt(sum(x[i]^2) / n)
            // Parameters: input array, stride (1 = every sample), output, count

            var rms: Float = 0.0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))

            // MARK: Calculate Peak using vDSP
            // Peak is the maximum absolute value in the buffer.
            // vDSP_maxmgv finds: max(|x[i]|)
            // Useful for detecting clipping (when peak >= 1.0).

            var peak: Float = 0.0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount))

            maxRMS = max(maxRMS, rms)
            maxPeak = max(maxPeak, peak)
        }

        // MARK: Update with Smoothing
        lock.lock()

        // Exponential moving average for RMS.
        // newValue = oldValue * (1 - factor) + sample * factor
        // This creates a smooth transition between values.
        currentRMS = currentRMS * (1.0 - smoothingFactor) + maxRMS * smoothingFactor

        // Peak hold with decay.
        // The peak only goes down slowly (0.95 multiplier), creating a "hold" effect
        // where you can see recent peaks.
        currentPeak = max(currentPeak * 0.95, maxPeak)

        lock.unlock()
    }

    // MARK: - Accessors
    // These properties provide thread-safe read access to current levels.

    /// Get current RMS level as normalized value (0.0 to 1.0)
    var rmsLevel: Float {
        lock.lock()
        defer { lock.unlock() }  // defer ensures unlock happens even if we return early
        return currentRMS
    }

    /// Get current peak level as normalized value (0.0 to 1.0)
    var peakLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return min(currentPeak, 1.0)  // Clamp to 1.0 max
    }

    /// Get current RMS level in dB (-60 to 0)
    var rmsDB: Float {
        let level = rmsLevel
        guard level > 0 else { return Self.minDB }
        // dB = 20 * log10(amplitude)
        // max() ensures we don't go below minDB
        return max(Self.minDB, 20.0 * log10(level))
    }

    /// Get current peak level in dB (-60 to 0)
    var peakDB: Float {
        let level = peakLevel
        guard level > 0 else { return Self.minDB }
        return max(Self.minDB, 20.0 * log10(level))
    }

    // MARK: - Utility Functions

    /// Convert dB value to normalized 0-1 range for UI display.
    /// -60 dB → 0.0, 0 dB → 1.0
    static func dbToNormalized(_ db: Float) -> Float {
        let clamped = max(minDB, min(maxDB, db))
        return (clamped - minDB) / (maxDB - minDB)
    }

    /// Reset levels to zero (called when recording stops).
    func reset() {
        lock.lock()
        currentRMS = 0.0
        currentPeak = 0.0
        lock.unlock()
    }
}
