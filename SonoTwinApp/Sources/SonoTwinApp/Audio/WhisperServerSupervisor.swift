import Darwin
import Foundation

actor WhisperServerSupervisor {
    struct Configuration: Sendable {
        let executableURL: URL
        let modelURL: URL
        let requestedLanguage: String
        let port: UInt16?
        let threads: Int
        let startupTimeout: TimeInterval
        let requestTimeout: TimeInterval
        let shutdownTimeout: TimeInterval
        let maxDiagnosticBytes: Int

        init(
            executableURL: URL,
            modelURL: URL,
            requestedLanguage: String = "auto",
            port: UInt16? = nil,
            threads: Int = 4,
            startupTimeout: TimeInterval = 10,
            requestTimeout: TimeInterval = 15,
            shutdownTimeout: TimeInterval = 3,
            maxDiagnosticBytes: Int = 64 * 1_024
        ) {
            self.executableURL = executableURL
            self.modelURL = modelURL
            self.requestedLanguage = requestedLanguage
            self.port = port
            self.threads = threads
            self.startupTimeout = startupTimeout
            self.requestTimeout = requestTimeout
            self.shutdownTimeout = shutdownTimeout
            self.maxDiagnosticBytes = maxDiagnosticBytes
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case starting
        case ready
        case stopping
        case stopped
        case failed(String)
    }

    struct Snapshot: Equatable, Sendable {
        let state: State
        let processIdentifier: Int32?
        let port: UInt16?
        let requestedLanguage: String
        let resolvedLanguage: String?
        let queuedRequestCount: Int
        let diagnostics: String
    }

    struct Segment: Equatable, Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
    }

    struct Inference: Equatable, Sendable {
        let source: TranscriptionSource
        let chunk: TranscriptionChunkPipeline.Chunk
        let language: String
        let durationSeconds: Double
        let text: String
        let segments: [Segment]
    }

    enum SupervisorError: Error, Equatable, LocalizedError {
        case invalidConfiguration(String)
        case executableNotRunnable(String)
        case modelNotReadable(String)
        case unavailableState(String)
        case portAllocationFailed(Int32)
        case launchFailed(String)
        case startupTimedOut(TimeInterval)
        case processExited(Int32)
        case invalidChunk(String)
        case requestFailed(String)
        case invalidResponse(Int, String)
        case malformedResponse(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                return "Invalid whisper-server configuration: \(message)"
            case .executableNotRunnable(let path):
                return "whisper-server is not executable at \(path)"
            case .modelNotReadable(let path):
                return "Whisper model is not readable at \(path)"
            case .unavailableState(let state):
                return "whisper-server is unavailable while \(state)"
            case .portAllocationFailed(let code):
                return "Unable to allocate a loopback port: errno \(code)"
            case .launchFailed(let message):
                return "Unable to launch whisper-server: \(message)"
            case .startupTimedOut(let timeout):
                return "whisper-server did not become ready within \(timeout) seconds"
            case .processExited(let status):
                return "whisper-server exited with status \(status)"
            case .invalidChunk(let path):
                return "Only finalized readable WAV chunks can be transcribed: \(path)"
            case .requestFailed(let message):
                return "Whisper inference request failed: \(message)"
            case .invalidResponse(let status, let body):
                return "whisper-server returned HTTP \(status): \(body)"
            case .malformedResponse(let message):
                return "Invalid whisper-server response: \(message)"
            case .stopped:
                return "whisper-server was stopped"
            }
        }
    }

    typealias StateHandler = @Sendable (Snapshot) -> Void

    private struct ServerResponse: Decodable {
        struct ServerSegment: Decodable {
            let start: Double?
            let end: Double?
            let text: String
        }

        let language: String
        let duration: Double?
        let text: String
        let segments: [ServerSegment]
    }

    private struct PendingInference {
        let chunk: TranscriptionChunkPipeline.Chunk
        let continuation: CheckedContinuation<Inference, Error>
    }

    private let configuration: Configuration
    private let onStateChange: StateHandler?
    private let urlSession: URLSession

    private var state = State.idle
    private var process: Process?
    private var outputPipe: Pipe?
    private var selectedPort: UInt16?
    private var resolvedLanguage: String?
    private var diagnosticBuffer = Data()
    private var pendingInferences: [PendingInference] = []
    private var inferenceHead = 0
    private var drainTask: Task<Void, Never>?

    init(configuration: Configuration, onStateChange: StateHandler? = nil) throws {
        guard !configuration.requestedLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupervisorError.invalidConfiguration("requestedLanguage must not be empty")
        }
        guard configuration.threads > 0 else {
            throw SupervisorError.invalidConfiguration("threads must be positive")
        }
        guard configuration.startupTimeout > 0,
              configuration.requestTimeout > 0,
              configuration.shutdownTimeout > 0 else {
            throw SupervisorError.invalidConfiguration("timeouts must be positive")
        }
        guard configuration.maxDiagnosticBytes > 0 else {
            throw SupervisorError.invalidConfiguration("maxDiagnosticBytes must be positive")
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpMaximumConnectionsPerHost = 1
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout

        self.configuration = configuration
        self.onStateChange = onStateChange
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    func start() async throws {
        guard drainTask == nil else {
            throw SupervisorError.unavailableState("finishing queued inference")
        }
        switch state {
        case .idle, .stopped, .failed:
            break
        default:
            throw SupervisorError.unavailableState(stateDescription)
        }

        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            let error = SupervisorError.executableNotRunnable(configuration.executableURL.path)
            transition(to: .failed(error.localizedDescription))
            throw error
        }
        guard FileManager.default.isReadableFile(atPath: configuration.modelURL.path) else {
            let error = SupervisorError.modelNotReadable(configuration.modelURL.path)
            transition(to: .failed(error.localizedDescription))
            throw error
        }

        let port: UInt16
        do {
            port = try configuration.port ?? Self.allocateLoopbackPort()
        } catch {
            let supervisorError = error as? SupervisorError
                ?? .launchFailed(error.localizedDescription)
            transition(to: .failed(supervisorError.localizedDescription))
            throw supervisorError
        }

        selectedPort = port
        resolvedLanguage = nil
        diagnosticBuffer.removeAll(keepingCapacity: true)
        transition(to: .starting)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = [
            "--model", configuration.modelURL.path,
            "--language", configuration.requestedLanguage,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--threads", String(configuration.threads),
            "--no-language-probabilities"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.appendDiagnostics(data) }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let identifier = terminatedProcess.processIdentifier
            Task { await self?.processDidExit(identifier: identifier, status: status) }
        }

        self.process = process
        self.outputPipe = pipe

        do {
            try process.run()
        } catch {
            cleanupProcessResources()
            let supervisorError = SupervisorError.launchFailed(error.localizedDescription)
            transition(to: .failed(supervisorError.localizedDescription))
            throw supervisorError
        }

        do {
            try await waitUntilReady(port: port)
            guard process.isRunning else {
                throw SupervisorError.processExited(process.terminationStatus)
            }
            transition(to: .ready)
        } catch {
            let supervisorError = error as? SupervisorError
                ?? .launchFailed(error.localizedDescription)
            if process.isRunning {
                process.terminate()
                await waitForProcessExit(process, timeout: configuration.shutdownTimeout)
            }
            cleanupProcessResources()
            transition(to: .failed(supervisorError.localizedDescription))
            throw supervisorError
        }
    }

    func transcribe(_ chunk: TranscriptionChunkPipeline.Chunk) async throws -> Inference {
        guard case .ready = state else {
            throw SupervisorError.unavailableState(stateDescription)
        }
        guard chunk.url.pathExtension.lowercased() == "wav",
              FileManager.default.isReadableFile(atPath: chunk.url.path) else {
            throw SupervisorError.invalidChunk(chunk.url.path)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingInferences.append(
                PendingInference(chunk: chunk, continuation: continuation)
            )
            if drainTask == nil {
                drainTask = Task { await self.drainInferenceQueue() }
            }
            publishSnapshot()
        }
    }

    func restart() async throws {
        await stop()
        try await start()
    }

    func stop() async {
        switch state {
        case .idle, .stopped:
            transition(to: .stopped)
            return
        default:
            break
        }

        transition(to: .stopping)
        failQueuedInferences(with: .stopped)

        if let process, process.isRunning {
            process.terminate()
            await waitForProcessExit(process, timeout: configuration.shutdownTimeout)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                await waitForProcessExit(process, timeout: 1)
            }
        }

        let activeDrain = drainTask
        await activeDrain?.value
        cleanupProcessResources()
        transition(to: .stopped)
    }

    func snapshot() -> Snapshot {
        makeSnapshot()
    }

    private var stateDescription: String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .ready: return "ready"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed(let message): return "failed: \(message)"
        }
    }

    private func transition(to newState: State) {
        state = newState
        publishSnapshot()
    }

    private func publishSnapshot() {
        onStateChange?(makeSnapshot())
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            state: state,
            processIdentifier: process?.isRunning == true ? process?.processIdentifier : nil,
            port: selectedPort,
            requestedLanguage: configuration.requestedLanguage,
            resolvedLanguage: resolvedLanguage,
            queuedRequestCount: pendingInferences.count - inferenceHead,
            diagnostics: String(decoding: diagnosticBuffer, as: UTF8.self)
        )
    }

    private func appendDiagnostics(_ data: Data) {
        diagnosticBuffer.append(data)
        if diagnosticBuffer.count > configuration.maxDiagnosticBytes {
            diagnosticBuffer.removeFirst(
                diagnosticBuffer.count - configuration.maxDiagnosticBytes
            )
        }
        publishSnapshot()
    }

    private func processDidExit(identifier: Int32, status: Int32) {
        guard process?.processIdentifier == identifier else { return }
        switch state {
        case .stopping, .stopped:
            return
        default:
            let error = SupervisorError.processExited(status)
            transition(to: .failed(error.localizedDescription))
            failQueuedInferences(with: error)
        }
    }

    private func waitUntilReady(port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(configuration.startupTimeout)
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!

        while Date() < deadline {
            if let process, !process.isRunning {
                throw SupervisorError.processExited(process.terminationStatus)
            }

            var request = URLRequest(url: healthURL)
            request.timeoutInterval = min(0.5, configuration.startupTimeout)
            if let (_, response) = try? await urlSession.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw SupervisorError.startupTimedOut(configuration.startupTimeout)
    }

    private func drainInferenceQueue() async {
        while inferenceHead < pendingInferences.count {
            guard case .ready = state else {
                failQueuedInferences(with: .unavailableState(stateDescription))
                break
            }

            let pending = pendingInferences[inferenceHead]
            inferenceHead += 1
            publishSnapshot()

            do {
                let result = try await performInference(pending.chunk)
                pending.continuation.resume(returning: result)
            } catch {
                pending.continuation.resume(throwing: error)
                if case .failed = state {
                    failQueuedInferences(
                        with: error as? SupervisorError
                            ?? .requestFailed(error.localizedDescription)
                    )
                    break
                }
            }
        }

        pendingInferences.removeAll(keepingCapacity: true)
        inferenceHead = 0
        drainTask = nil
        publishSnapshot()
    }

    private func performInference(_ chunk: TranscriptionChunkPipeline.Chunk) async throws -> Inference {
        guard let port = selectedPort else {
            throw SupervisorError.unavailableState("missing server port")
        }

        let language = resolvedLanguage ?? configuration.requestedLanguage
        let boundary = "SonoTwin-\(UUID().uuidString)"
        let audio: Data
        do {
            audio = try Data(contentsOf: chunk.url)
        } catch {
            throw SupervisorError.invalidChunk(chunk.url.path)
        }

        let body = Self.multipartBody(
            boundary: boundary,
            filename: chunk.url.lastPathComponent,
            audio: audio,
            fields: [
                "language": language,
                "response_format": "verbose_json",
                "no_language_probabilities": "true"
            ]
        )
        let inferenceURL = URL(string: "http://127.0.0.1:\(port)/inference")!
        var urlRequest = URLRequest(url: inferenceURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.requestTimeout
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.httpBody = body

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await urlSession.data(for: urlRequest)
        } catch {
            let supervisorError = SupervisorError.requestFailed(error.localizedDescription)
            transition(to: .failed(supervisorError.localizedDescription))
            if let process, process.isRunning {
                process.terminate()
            }
            throw supervisorError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupervisorError.malformedResponse("missing HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(decoding: responseData.prefix(1_024), as: UTF8.self)
            throw SupervisorError.invalidResponse(httpResponse.statusCode, body)
        }

        let serverResponse: ServerResponse
        do {
            serverResponse = try JSONDecoder().decode(ServerResponse.self, from: responseData)
        } catch {
            throw SupervisorError.malformedResponse(error.localizedDescription)
        }

        let normalizedText = serverResponse.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.requestedLanguage == "auto", resolvedLanguage == nil,
           !serverResponse.language.isEmpty, !normalizedText.isEmpty {
            resolvedLanguage = serverResponse.language
            publishSnapshot()
        }

        return Inference(
            source: chunk.source,
            chunk: chunk,
            language: serverResponse.language,
            durationSeconds: serverResponse.duration ?? 0,
            text: normalizedText,
            segments: serverResponse.segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = segment.start, let end = segment.end,
                      end >= start, !text.isEmpty else {
                    return nil
                }
                return Segment(
                    startSeconds: start,
                    endSeconds: end,
                    text: text
                )
            }
        )
    }

    private func failQueuedInferences(with error: SupervisorError) {
        guard inferenceHead < pendingInferences.count else { return }
        for index in inferenceHead..<pendingInferences.count {
            pendingInferences[index].continuation.resume(throwing: error)
        }
        pendingInferences.removeSubrange(inferenceHead...)
    }

    private func waitForProcessExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func cleanupProcessResources() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        outputPipe = nil
        process = nil
    }

    private static func multipartBody(
        boundary: String,
        filename: String,
        audio: Data,
        fields: [String: String]
    ) -> Data {
        var body = Data()
        body.append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n"
                .data(using: .utf8)!
        )
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)

        for key in fields.keys.sorted() {
            body.append(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n"
                    .data(using: .utf8)!
            )
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func allocateLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SupervisorError.portAllocationFailed(errno)
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw SupervisorError.portAllocationFailed(errno)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw SupervisorError.portAllocationFailed(errno)
        }

        return UInt16(bigEndian: address.sin_port)
    }
}
