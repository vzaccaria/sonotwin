import Foundation

final class SourceTranscriptionPipelines: @unchecked Sendable {
    struct Configuration: Sendable {
        let rootDirectory: URL
        let sources: Set<TranscriptionSource>
        let inputSampleRate: Int
        let inputChannels: Int
        let outputSampleRate: Int
        let cadenceMilliseconds: Int64
        let overlapMilliseconds: Int64
        let maxQueuedBytesPerSource: Int

        init(
            rootDirectory: URL,
            sources: Set<TranscriptionSource>,
            inputSampleRate: Int = 48_000,
            inputChannels: Int = 2,
            outputSampleRate: Int = 16_000,
            cadenceMilliseconds: Int64 = 5_000,
            overlapMilliseconds: Int64 = 1_000,
            maxQueuedBytesPerSource: Int = 1_920_000
        ) {
            self.rootDirectory = rootDirectory
            self.sources = sources
            self.inputSampleRate = inputSampleRate
            self.inputChannels = inputChannels
            self.outputSampleRate = outputSampleRate
            self.cadenceMilliseconds = cadenceMilliseconds
            self.overlapMilliseconds = overlapMilliseconds
            self.maxQueuedBytesPerSource = maxQueuedBytesPerSource
        }
    }

    enum RoutingError: Error, Equatable, LocalizedError {
        case noSources

        var errorDescription: String? {
            switch self {
            case .noSources:
                return "At least one transcription source must be enabled"
            }
        }
    }

    typealias ChunkHandler = TranscriptionChunkPipeline.ChunkHandler
    typealias FailureHandler = @Sendable (
        TranscriptionSource,
        TranscriptionChunkPipeline.PipelineError
    ) -> Void

    private enum FinishResult: Sendable {
        case success
        case failure(TranscriptionChunkPipeline.PipelineError)
    }

    private let pipelines: [TranscriptionSource: TranscriptionChunkPipeline]

    init(
        configuration: Configuration,
        onChunkReady: ChunkHandler? = nil,
        onFailure: FailureHandler? = nil
    ) throws {
        guard !configuration.sources.isEmpty else {
            throw RoutingError.noSources
        }

        var pipelines: [TranscriptionSource: TranscriptionChunkPipeline] = [:]
        for source in configuration.sources {
            let sourceDirectory = configuration.rootDirectory
                .appendingPathComponent(source.rawValue, isDirectory: true)
            pipelines[source] = try TranscriptionChunkPipeline(
                configuration: .init(
                    source: source,
                    chunksDirectory: sourceDirectory,
                    inputSampleRate: configuration.inputSampleRate,
                    inputChannels: configuration.inputChannels,
                    outputSampleRate: configuration.outputSampleRate,
                    cadenceMilliseconds: configuration.cadenceMilliseconds,
                    overlapMilliseconds: configuration.overlapMilliseconds,
                    maxQueuedBytes: configuration.maxQueuedBytesPerSource
                ),
                onChunkReady: onChunkReady,
                onFailure: { error in onFailure?(source, error) }
            )
        }
        self.pipelines = pipelines
    }

    func contains(_ source: TranscriptionSource) -> Bool {
        pipelines[source] != nil
    }

    @discardableResult
    func append(
        _ samples: Data,
        source: TranscriptionSource,
        firstSampleMilliseconds: Int64
    ) -> Bool {
        pipelines[source]?.append(
            samples,
            firstSampleMilliseconds: firstSampleMilliseconds
        ) ?? false
    }

    func finish() async throws {
        let pipelines = Array(pipelines.values)
        var firstFailure: TranscriptionChunkPipeline.PipelineError?

        await withTaskGroup(of: FinishResult.self) { group in
            for pipeline in pipelines {
                group.addTask {
                    do {
                        try await pipeline.finish()
                        return .success
                    } catch let error as TranscriptionChunkPipeline.PipelineError {
                        return .failure(error)
                    } catch {
                        return .failure(.ioFailure(error.localizedDescription))
                    }
                }
            }

            for await result in group {
                if case .failure(let error) = result, firstFailure == nil {
                    firstFailure = error
                }
            }
        }

        if let firstFailure {
            throw firstFailure
        }
    }
}
