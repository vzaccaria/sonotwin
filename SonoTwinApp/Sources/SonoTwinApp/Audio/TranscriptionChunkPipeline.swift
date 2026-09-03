import AVFoundation
import Foundation

final class TranscriptionChunkPipeline: @unchecked Sendable {
    struct Configuration: Sendable {
        let chunksDirectory: URL
        let inputSampleRate: Int
        let inputChannels: Int
        let outputSampleRate: Int
        let cadenceMilliseconds: Int64
        let overlapMilliseconds: Int64
        let maxQueuedBytes: Int

        init(
            chunksDirectory: URL,
            inputSampleRate: Int = 48_000,
            inputChannels: Int = 2,
            outputSampleRate: Int = 16_000,
            cadenceMilliseconds: Int64 = 5_000,
            overlapMilliseconds: Int64 = 1_000,
            maxQueuedBytes: Int = 1_920_000
        ) {
            self.chunksDirectory = chunksDirectory
            self.inputSampleRate = inputSampleRate
            self.inputChannels = inputChannels
            self.outputSampleRate = outputSampleRate
            self.cadenceMilliseconds = cadenceMilliseconds
            self.overlapMilliseconds = overlapMilliseconds
            self.maxQueuedBytes = maxQueuedBytes
        }
    }

    struct Chunk: Equatable, Sendable {
        let sequence: Int
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let url: URL
    }

    enum PipelineError: Error, Equatable, LocalizedError {
        case invalidConfiguration(String)
        case invalidInputByteCount(Int)
        case backlogExceeded(limitBytes: Int)
        case finishAlreadyRequested
        case converterUnavailable
        case conversionFailed(String)
        case chunkAlreadyExists(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                return "Invalid transcription chunk configuration: \(message)"
            case .invalidInputByteCount(let count):
                return "PCM input byte count \(count) is not frame-aligned"
            case .backlogExceeded(let limitBytes):
                return "Transcription chunk backlog exceeded \(limitBytes) bytes"
            case .finishAlreadyRequested:
                return "Transcription chunk pipeline finish was already requested"
            case .converterUnavailable:
                return "Unable to create the transcription audio converter"
            case .conversionFailed(let message):
                return "Transcription audio conversion failed: \(message)"
            case .chunkAlreadyExists(let path):
                return "Transcription chunk already exists: \(path)"
            case .ioFailure(let message):
                return "Transcription chunk I/O failed: \(message)"
            }
        }
    }

    typealias ChunkHandler = @Sendable (Chunk) -> Void
    typealias FailureHandler = @Sendable (PipelineError) -> Void

    private enum Lifecycle {
        case accepting
        case finishing
        case finished
    }

    private let configuration: Configuration
    private let processingQueue = DispatchQueue(label: "com.sonotwin.transcription-chunks")
    private let stateLock = NSLock()
    private let onChunkReady: ChunkHandler?
    private let onFailure: FailureHandler?

    private let bytesPerInputFrame: Int
    private let cadenceInputFrames: Int64
    private let overlapInputFrames: Int64
    private let cadenceInputBytes: Int
    private let overlapInputBytes: Int

    // Protected by stateLock.
    private var lifecycle = Lifecycle.accepting
    private var queuedBytes = 0
    private var terminalError: PipelineError?

    // Accessed only by processingQueue.
    private var cadenceInput = Data()
    private var precedingOverlap = Data()
    private var processedInputFrames: Int64 = 0
    private var nextSequence = 0

    init(
        configuration: Configuration,
        onChunkReady: ChunkHandler? = nil,
        onFailure: FailureHandler? = nil
    ) throws {
        guard configuration.inputSampleRate > 0 else {
            throw PipelineError.invalidConfiguration("inputSampleRate must be positive")
        }
        guard configuration.inputChannels > 0 else {
            throw PipelineError.invalidConfiguration("inputChannels must be positive")
        }
        guard configuration.outputSampleRate > 0 else {
            throw PipelineError.invalidConfiguration("outputSampleRate must be positive")
        }
        guard configuration.cadenceMilliseconds > 0 else {
            throw PipelineError.invalidConfiguration("cadenceMilliseconds must be positive")
        }
        guard configuration.overlapMilliseconds >= 0,
              configuration.overlapMilliseconds < configuration.cadenceMilliseconds else {
            throw PipelineError.invalidConfiguration("overlapMilliseconds must be non-negative and shorter than cadence")
        }
        guard configuration.maxQueuedBytes > 0 else {
            throw PipelineError.invalidConfiguration("maxQueuedBytes must be positive")
        }

        let cadenceFrames = Int64(configuration.inputSampleRate) * configuration.cadenceMilliseconds / 1_000
        let overlapFrames = Int64(configuration.inputSampleRate) * configuration.overlapMilliseconds / 1_000
        guard cadenceFrames > 0 else {
            throw PipelineError.invalidConfiguration("cadence resolves to zero input frames")
        }

        self.configuration = configuration
        self.onChunkReady = onChunkReady
        self.onFailure = onFailure
        self.bytesPerInputFrame = configuration.inputChannels * MemoryLayout<Int16>.size
        self.cadenceInputFrames = cadenceFrames
        self.overlapInputFrames = overlapFrames
        self.cadenceInputBytes = Int(cadenceFrames) * configuration.inputChannels * MemoryLayout<Int16>.size
        self.overlapInputBytes = Int(overlapFrames) * configuration.inputChannels * MemoryLayout<Int16>.size

        try FileManager.default.createDirectory(
            at: configuration.chunksDirectory,
            withIntermediateDirectories: true
        )
        cadenceInput.reserveCapacity(cadenceInputBytes)
        precedingOverlap.reserveCapacity(overlapInputBytes)
    }

    @discardableResult
    func append(_ samples: Data) -> Bool {
        guard !samples.isEmpty else { return true }

        var rejection: PipelineError?
        stateLock.lock()

        if lifecycle != .accepting || terminalError != nil {
            stateLock.unlock()
            return false
        }

        if samples.count % bytesPerInputFrame != 0 {
            rejection = .invalidInputByteCount(samples.count)
        } else if samples.count > configuration.maxQueuedBytes - queuedBytes {
            rejection = .backlogExceeded(limitBytes: configuration.maxQueuedBytes)
        }

        if let rejection {
            terminalError = rejection
            stateLock.unlock()
            processingQueue.async { [onFailure] in onFailure?(rejection) }
            return false
        }

        queuedBytes += samples.count
        processingQueue.async { [self, samples] in
            defer { releaseQueuedBytes(samples.count) }
            guard currentError == nil else { return }

            do {
                try process(samples)
            } catch {
                recordFailure(mapError(error))
            }
        }
        stateLock.unlock()
        return true
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            guard lifecycle == .accepting else {
                stateLock.unlock()
                continuation.resume(throwing: PipelineError.finishAlreadyRequested)
                return
            }

            lifecycle = .finishing
            processingQueue.async { [self] in
                if currentError == nil {
                    do {
                        try flushFinalChunk()
                    } catch {
                        recordFailure(mapError(error))
                    }
                }

                stateLock.lock()
                lifecycle = .finished
                let result = terminalError
                stateLock.unlock()

                if let result {
                    continuation.resume(throwing: result)
                } else {
                    continuation.resume()
                }
            }
            stateLock.unlock()
        }
    }

    private var currentError: PipelineError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminalError
    }

    private func releaseQueuedBytes(_ count: Int) {
        stateLock.lock()
        queuedBytes -= count
        stateLock.unlock()
    }

    private func recordFailure(_ error: PipelineError) {
        stateLock.lock()
        let isFirstFailure = terminalError == nil
        if isFirstFailure {
            terminalError = error
        }
        stateLock.unlock()

        if isFirstFailure {
            onFailure?(error)
        }
    }

    private func mapError(_ error: Error) -> PipelineError {
        if let pipelineError = error as? PipelineError {
            return pipelineError
        }
        return .ioFailure(error.localizedDescription)
    }

    private func process(_ samples: Data) throws {
        var cursor = samples.startIndex

        while cursor < samples.endIndex {
            let required = cadenceInputBytes - cadenceInput.count
            let available = samples.distance(from: cursor, to: samples.endIndex)
            let count = min(required, available)
            let end = samples.index(cursor, offsetBy: count)
            cadenceInput.append(contentsOf: samples[cursor..<end])
            cursor = end

            if cadenceInput.count == cadenceInputBytes {
                try emitChunk(newInputFrames: cadenceInputFrames)
                processedInputFrames += cadenceInputFrames
                precedingOverlap = Data(cadenceInput.suffix(overlapInputBytes))
                cadenceInput.removeAll(keepingCapacity: true)
            }
        }
    }

    private func flushFinalChunk() throws {
        guard !cadenceInput.isEmpty else { return }
        let finalFrames = Int64(cadenceInput.count / bytesPerInputFrame)
        try emitChunk(newInputFrames: finalFrames)
        processedInputFrames += finalFrames
        cadenceInput.removeAll(keepingCapacity: false)
    }

    private func emitChunk(newInputFrames: Int64) throws {
        let overlapFrames = Int64(precedingOverlap.count / bytesPerInputFrame)
        let startFrame = processedInputFrames - overlapFrames
        let endFrame = processedInputFrames + newInputFrames

        var window = Data(capacity: precedingOverlap.count + cadenceInput.count)
        window.append(precedingOverlap)
        window.append(cadenceInput)

        let converted = try convertToWhisperPCM(window)
        let startMilliseconds = milliseconds(forInputFrame: startFrame)
        let endMilliseconds = milliseconds(forInputFrame: endFrame)
        let stem = String(
            format: "%06d_%012lld_%012lld",
            nextSequence,
            startMilliseconds,
            endMilliseconds
        )
        let temporaryURL = configuration.chunksDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension("part")
        let finalURL = configuration.chunksDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension("wav")

        guard !FileManager.default.fileExists(atPath: temporaryURL.path),
              !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw PipelineError.chunkAlreadyExists(finalURL.path)
        }

        do {
            let writer = try WAVWriter(
                outputPath: temporaryURL,
                sampleRate: UInt32(configuration.outputSampleRate),
                channels: 1,
                bitsPerSample: 16
            )
            try writer.appendSamplesThrowing(converted)
            try writer.finalize()
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        let chunk = Chunk(
            sequence: nextSequence,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            url: finalURL
        )
        nextSequence += 1
        onChunkReady?(chunk)
    }

    private func milliseconds(forInputFrame frame: Int64) -> Int64 {
        frame * 1_000 / Int64(configuration.inputSampleRate)
    }

    private func convertToWhisperPCM(_ samples: Data) throws -> Data {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.inputSampleRate),
            channels: AVAudioChannelCount(configuration.inputChannels),
            interleaved: true
        ), let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(configuration.outputSampleRate),
            channels: 1
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PipelineError.converterUnavailable
        }

        converter.primeMethod = .none
        let inputFrameCount = AVAudioFrameCount(samples.count / bytesPerInputFrame)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCount
        ) else {
            throw PipelineError.converterUnavailable
        }
        inputBuffer.frameLength = inputFrameCount

        let inputAudioBuffer = inputBuffer.mutableAudioBufferList
        guard let inputStorage = inputAudioBuffer.pointee.mBuffers.mData else {
            throw PipelineError.converterUnavailable
        }
        samples.copyBytes(
            to: inputStorage.assumingMemoryBound(to: UInt8.self),
            count: samples.count
        )
        inputAudioBuffer.pointee.mBuffers.mDataByteSize = UInt32(samples.count)

        let ratio = Double(configuration.outputSampleRate) / Double(configuration.inputSampleRate)
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrameCount) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw PipelineError.converterUnavailable
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || conversionError != nil {
            throw PipelineError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown AVAudioConverter error"
            )
        }
        guard let channel = outputBuffer.floatChannelData?[0] else {
            throw PipelineError.conversionFailed("converter returned no mono samples")
        }

        let expectedFrameCount = Int((Double(inputFrameCount) * ratio).rounded())
        guard Int(outputBuffer.frameLength) >= expectedFrameCount else {
            throw PipelineError.conversionFailed(
                "converter returned \(outputBuffer.frameLength) frames; expected \(expectedFrameCount)"
            )
        }
        var output = Data(count: expectedFrameCount * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { rawOutput in
            let destination = rawOutput.bindMemory(to: Int16.self)
            for frame in 0..<expectedFrameCount {
                let clamped = max(-1.0, min(1.0, channel[frame]))
                destination[frame] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return output
    }
}
