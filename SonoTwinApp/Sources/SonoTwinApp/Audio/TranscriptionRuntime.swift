import Foundation

actor TranscriptionRuntime {
    struct Settings: Equatable, Sendable {
        let executableURL: URL
        let modelURL: URL
        let requestedLanguage: String
    }

    enum State: String, Codable, Sendable {
        case disabled
        case idle
        case checking
        case ready
        case active
        case lagging
        case draining
        case complete
        case failed
    }

    struct Snapshot: Equatable, Sendable {
        let state: State
        let serverState: WhisperServerSupervisor.State
        let serverHealthy: Bool
        let bundleURL: URL?
        let transcriptURL: URL?
        let jsonlURL: URL?
        let lastCompletedSequence: Int?
        let backlog: Int
        let lagMilliseconds: Int64
        let error: String?

        static let idle = Snapshot(
            state: .idle,
            serverState: .idle,
            serverHealthy: false,
            bundleURL: nil,
            transcriptURL: nil,
            jsonlURL: nil,
            lastCompletedSequence: nil,
            backlog: 0,
            lagMilliseconds: 0,
            error: nil
        )
    }

    typealias StatusHandler = @Sendable (Snapshot) -> Void

    private let onStatusChange: StatusHandler?
    private var supervisor: WhisperServerSupervisor?
    private var supervisorSettings: Settings?
    private var supervisorGeneration = UUID()
    private var serverState = WhisperServerSupervisor.State.idle
    private var state = State.idle
    private var store: TranscriptSessionStore?
    private var queue: TranscriptionEventQueue?
    private var workerTask: Task<Void, Never>?
    private var sessionDrainTask: Task<Void, Never>?
    private var backlog = 0
    private var lagMilliseconds: Int64 = 0
    private var lastCompletedSequence: Int?
    private var bundleURL: URL?
    private var transcriptURL: URL?
    private var jsonlURL: URL?
    private var sessionError: String?
    private var sessionHadFailure = false

    init(onStatusChange: StatusHandler? = nil) {
        self.onStatusChange = onStatusChange
    }

    func checkServer(settings: Settings) async throws {
        try await ensureServer(settings: settings)
        state = .ready
        sessionError = nil
        publishSnapshot()
    }

    func startSession(
        recordingURL: URL,
        sources: Set<TranscriptionSource>,
        settings: Settings
    ) async throws -> SourceTranscriptionPipelines {
        guard workerTask == nil, sessionDrainTask == nil else {
            throw RuntimeError.sessionAlreadyActive
        }
        guard !sources.isEmpty else {
            throw RuntimeError.noSources
        }

        try await ensureServer(settings: settings)
        guard let supervisor else {
            throw RuntimeError.serverUnavailable
        }

        let bundleURL = Self.availableBundleURL(for: recordingURL)
        let store = try TranscriptSessionStore(
            configuration: .init(
                bundleURL: bundleURL,
                recordingURL: recordingURL,
                executableURL: settings.executableURL,
                modelURL: settings.modelURL,
                requestedLanguage: settings.requestedLanguage
            )
        )
        try await store.setLifecycle(.active)

        let queue = TranscriptionEventQueue { [weak self] depth in
            Task { await self?.updateBacklog(depth) }
        }
        let sourcePipelines = try SourceTranscriptionPipelines(
            configuration: .init(
                rootDirectory: store.chunksURL,
                sources: sources
            ),
            onChunkReady: { queue.yield(.chunk($0)) },
            onFailure: { source, error in
                queue.yield(.sourceFailure(source, error.localizedDescription))
            }
        )

        self.store = store
        self.queue = queue
        self.bundleURL = store.bundleURL
        self.transcriptURL = store.transcriptURL
        self.jsonlURL = store.jsonlURL
        self.backlog = 0
        self.lagMilliseconds = 0
        self.lastCompletedSequence = nil
        self.sessionError = nil
        self.sessionHadFailure = false
        self.state = .active
        self.workerTask = Task { [weak self, stream = queue.stream] in
            await self?.consume(stream, store: store, supervisor: supervisor, queue: queue)
        }
        publishSnapshot()
        return sourcePipelines
    }

    @discardableResult
    func beginFinishingSession() -> Snapshot {
        guard sessionDrainTask == nil,
              let queue,
              let workerTask,
              let store else {
            return makeSnapshot()
        }

        let markDraining = !sessionHadFailure
        if markDraining {
            state = .draining
        }
        queue.finish()
        sessionDrainTask = Task { [weak self] in
            if markDraining {
                try? await store.setLifecycle(.draining)
            }
            await workerTask.value
            await self?.completeFinishingSession(queue: queue, store: store)
        }
        publishSnapshot()
        return makeSnapshot()
    }

    func finishSession() async {
        _ = beginFinishingSession()
        let drainTask = sessionDrainTask
        await drainTask?.value
    }

    private func completeFinishingSession(
        queue: TranscriptionEventQueue,
        store: TranscriptSessionStore
    ) async {
        backlog = queue.depth

        if sessionHadFailure || backlog > 0 {
            state = .failed
            let error = sessionError ?? "Transcription stopped with pending chunks"
            try? await store.setLifecycle(.incomplete, error: error)
        } else {
            state = .complete
            try? await store.setLifecycle(.complete)
            try? await store.removeChunksAfterCompletion()
        }
        await refreshStoreSnapshot(store)

        workerTask = nil
        self.queue = nil
        sessionDrainTask = nil
        publishSnapshot()
    }

    func shutdown() async {
        if workerTask != nil {
            await finishSession()
        }
        await supervisor?.stop()
        supervisor = nil
        supervisorSettings = nil
        serverState = .stopped
        if state != .complete && state != .failed {
            state = .idle
        }
        publishSnapshot()
    }

    func snapshot() -> Snapshot {
        makeSnapshot()
    }

    private func ensureServer(settings: Settings) async throws {
        let normalizedLanguage = settings.requestedLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLanguage.isEmpty else {
            throw RuntimeError.invalidLanguage
        }

        if supervisorSettings == settings, let supervisor,
           case .ready = await supervisor.snapshot().state {
            serverState = .ready
            return
        }

        if let supervisor {
            await supervisor.stop()
        }
        let generation = UUID()
        supervisorGeneration = generation

        state = .checking
        sessionError = nil
        publishSnapshot()

        do {
            let newSupervisor = try WhisperServerSupervisor(
                configuration: .init(
                    executableURL: settings.executableURL,
                    modelURL: settings.modelURL,
                    requestedLanguage: normalizedLanguage
                ),
                onStateChange: { [weak self] snapshot in
                    Task {
                        await self?.receiveServerSnapshot(
                            snapshot,
                            generation: generation
                        )
                    }
                }
            )
            supervisor = newSupervisor
            supervisorSettings = settings
            try await newSupervisor.start()
            serverState = .ready
        } catch {
            state = .failed
            sessionError = error.localizedDescription
            publishSnapshot()
            throw error
        }
    }

    private func consume(
        _ stream: AsyncStream<TranscriptionEventQueue.Event>,
        store: TranscriptSessionStore,
        supervisor: WhisperServerSupervisor,
        queue: TranscriptionEventQueue
    ) async {
        eventLoop: for await event in stream {
            switch event {
            case .sourceFailure(let source, let message):
                sessionHadFailure = true
                sessionError = "\(source.rawValue): \(message)"
                state = .failed
                try? await store.setLifecycle(.failed, error: sessionError)
                publishSnapshot()

            case .chunk(let chunk):
                do {
                    try await store.markProduced(chunk)
                    if !(await store.isTranscribed(chunk)) {
                        let inference = try await supervisor.transcribe(chunk)
                        _ = try await store.append(inference)
                    }
                    queue.completeChunk()
                    await refreshStoreSnapshot(store)
                } catch {
                    sessionHadFailure = true
                    sessionError = error.localizedDescription
                    state = .failed
                    try? await store.setLifecycle(.failed, error: sessionError)
                    publishSnapshot()
                    break eventLoop
                }
            }
        }
    }

    private func receiveServerSnapshot(
        _ snapshot: WhisperServerSupervisor.Snapshot,
        generation: UUID
    ) {
        guard generation == supervisorGeneration else { return }
        if serverState == .ready, snapshot.state == .starting {
            return
        }
        serverState = snapshot.state
        if case .failed(let message) = snapshot.state {
            sessionError = message
            state = .failed
        }
        publishSnapshot()
    }

    private func updateBacklog(_ depth: Int) {
        backlog = depth
        if state == .active || state == .lagging {
            state = depth > 2 || lagMilliseconds > 10_000 ? .lagging : .active
        }
        publishSnapshot()
    }

    private func refreshStoreSnapshot(_ store: TranscriptSessionStore) async {
        let snapshot = await store.snapshot()
        bundleURL = snapshot.bundleURL
        transcriptURL = snapshot.transcriptURL
        jsonlURL = snapshot.jsonlURL
        lastCompletedSequence = snapshot.lastSequence
        lagMilliseconds = snapshot.lagMilliseconds
        if state == .active || state == .lagging {
            state = backlog > 2 || lagMilliseconds > 10_000 ? .lagging : .active
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        onStatusChange?(makeSnapshot())
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            state: state,
            serverState: serverState,
            serverHealthy: serverState == .ready,
            bundleURL: bundleURL,
            transcriptURL: transcriptURL,
            jsonlURL: jsonlURL,
            lastCompletedSequence: lastCompletedSequence,
            backlog: backlog,
            lagMilliseconds: lagMilliseconds,
            error: sessionError
        )
    }

    private static func availableBundleURL(for recordingURL: URL) -> URL {
        let baseURL = recordingURL.deletingPathExtension()
        let preferred = baseURL.appendingPathExtension("sonotwin")
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            return preferred
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return baseURL
            .appendingPathExtension(formatter.string(from: Date()))
            .appendingPathExtension("sonotwin")
    }

    enum RuntimeError: Error, Equatable, LocalizedError {
        case sessionAlreadyActive
        case noSources
        case invalidLanguage
        case serverUnavailable

        var errorDescription: String? {
            switch self {
            case .sessionAlreadyActive:
                return "A transcription session is already active"
            case .noSources:
                return "At least one transcription source must be selected"
            case .invalidLanguage:
                return "Transcription language must not be empty"
            case .serverUnavailable:
                return "whisper-server is unavailable"
            }
        }
    }
}

final class TranscriptionEventQueue: @unchecked Sendable {
    enum Event: Sendable {
        case chunk(TranscriptionChunkPipeline.Chunk)
        case sourceFailure(TranscriptionSource, String)
    }

    let stream: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let onDepthChange: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var pendingChunks = 0
    private var finished = false

    init(onDepthChange: @escaping @Sendable (Int) -> Void) {
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.onDepthChange = onDepthChange
    }

    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingChunks
    }

    func yield(_ event: Event) {
        var depth: Int?
        lock.lock()
        if !finished, case .chunk = event {
            pendingChunks += 1
            depth = pendingChunks
        }
        let shouldYield = !finished
        lock.unlock()

        if shouldYield {
            continuation.yield(event)
        }
        if let depth {
            onDepthChange(depth)
        }
    }

    func completeChunk() {
        lock.lock()
        pendingChunks = max(0, pendingChunks - 1)
        let depth = pendingChunks
        lock.unlock()
        onDepthChange(depth)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.finish()
    }
}
