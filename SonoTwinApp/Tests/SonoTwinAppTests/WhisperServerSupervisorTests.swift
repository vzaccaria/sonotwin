import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct WhisperServerSupervisorTests {
    @Test
    func startsSerializesSourceTaggedInferenceAndStops() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let fixture = try FakeWhisperFixture()
        defer { fixture.remove() }

        let states = SupervisorStateCollector()
        let supervisor = try WhisperServerSupervisor(
            configuration: fixture.configuration,
            onStateChange: { states.record($0.state) }
        )

        try await supervisor.start()
        let ready = await supervisor.snapshot()
        #expect(ready.state == .ready)
        #expect(ready.processIdentifier != nil)
        #expect(ready.port != nil)

        let silentRequest = fixture.request(
            named: "silent.wav",
            source: .system,
            sequence: 0
        )
        let silent = try await supervisor.transcribe(silentRequest)
        #expect(silent.text.isEmpty)
        #expect((await supervisor.snapshot()).resolvedLanguage == nil)

        let microphoneRequest = fixture.request(
            named: "microphone.wav",
            source: .microphone,
            sequence: 1
        )
        let systemRequest = fixture.request(
            named: "system.wav",
            source: .system,
            sequence: 2
        )

        async let microphone = supervisor.transcribe(microphoneRequest)
        async let system = supervisor.transcribe(systemRequest)
        let results = try await [microphone, system]

        #expect(results.map(\.source) == [.microphone, .system])
        #expect(results.allSatisfy { $0.text == "active=1" })
        #expect(results.allSatisfy { $0.language == "italian" })
        #expect(results.allSatisfy { $0.segments == [.init(startSeconds: 0, endSeconds: 1, text: "prova")] })

        let afterInference = await supervisor.snapshot()
        #expect(afterInference.state == .ready)
        #expect(afterInference.processIdentifier == ready.processIdentifier)
        #expect(afterInference.resolvedLanguage == "italian")
        #expect(afterInference.queuedRequestCount == 0)

        let partialRequest = fixture.request(
            named: "partial.part",
            source: .microphone,
            sequence: 3
        )
        do {
            _ = try await supervisor.transcribe(partialRequest)
            Issue.record("a partial chunk must not be submitted")
        } catch {
            #expect(
                (error as? WhisperServerSupervisor.SupervisorError)
                    == .invalidChunk(partialRequest.url.path)
            )
        }

        await supervisor.stop()
        let stopped = await supervisor.snapshot()
        #expect(stopped.state == .stopped)
        #expect(stopped.processIdentifier == nil)
        #expect(states.contains(.starting))
        #expect(states.contains(.ready))
        #expect(states.contains(.stopping))
        #expect(states.contains(.stopped))
    }

    @Test
    func reportsMissingExecutableAndModel() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelURL = root.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: modelURL)
        let missingExecutable = root.appendingPathComponent("missing-server")
        let executableSupervisor = try WhisperServerSupervisor(
            configuration: .init(
                executableURL: missingExecutable,
                modelURL: modelURL
            )
        )

        do {
            try await executableSupervisor.start()
            Issue.record("a missing executable must fail startup")
        } catch {
            #expect(
                (error as? WhisperServerSupervisor.SupervisorError)
                    == .executableNotRunnable(missingExecutable.path)
            )
        }
        #expect(isFailed((await executableSupervisor.snapshot()).state))

        let missingModel = root.appendingPathComponent("missing-model.bin")
        let modelSupervisor = try WhisperServerSupervisor(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                modelURL: missingModel
            )
        )

        do {
            try await modelSupervisor.start()
            Issue.record("a missing model must fail startup")
        } catch {
            #expect(
                (error as? WhisperServerSupervisor.SupervisorError)
                    == .modelNotReadable(missingModel.path)
            )
        }
        #expect(isFailed((await modelSupervisor.snapshot()).state))
    }

    @Test
    func reportsStartupTimeoutAndTerminatesProcess() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let fixture = try FakeWhisperFixture(modelName: "never-ready.bin")
        defer { fixture.remove() }

        let supervisor = try WhisperServerSupervisor(
            configuration: fixture.configuration(startupTimeout: 0.3)
        )

        do {
            try await supervisor.start()
            Issue.record("a server that never becomes healthy must time out")
        } catch {
            #expect(
                (error as? WhisperServerSupervisor.SupervisorError)
                    == .startupTimedOut(0.3)
            )
        }

        let snapshot = await supervisor.snapshot()
        #expect(isFailed(snapshot.state))
        #expect(snapshot.processIdentifier == nil)
    }

    @Test
    func reportsUnexpectedServerExitDuringInference() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let fixture = try FakeWhisperFixture()
        defer { fixture.remove() }

        let supervisor = try WhisperServerSupervisor(configuration: fixture.configuration)
        try await supervisor.start()

        let crashRequest = fixture.request(
            named: "crash.wav",
            source: .system,
            sequence: 0
        )
        do {
            _ = try await supervisor.transcribe(crashRequest)
            Issue.record("an unexpected server exit must fail inference")
        } catch {
            #expect(error is WhisperServerSupervisor.SupervisorError)
        }

        let failed = await waitForFailure(supervisor)
        #expect(isFailed(failed.state))
        #expect(failed.processIdentifier == nil)
        await supervisor.stop()
    }

    @Test
    func integratesWithConfiguredWhisperServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executablePath = environment["WHISPER_SERVER_PATH"],
              let modelPath = environment["WHISPER_MODEL_PATH"],
              let wavPath = environment["WHISPER_TEST_WAV"] else {
            return
        }

        let supervisor = try WhisperServerSupervisor(
            configuration: .init(
                executableURL: URL(fileURLWithPath: executablePath),
                modelURL: URL(fileURLWithPath: modelPath),
                requestedLanguage: "auto",
                startupTimeout: 10,
                requestTimeout: 15,
                shutdownTimeout: 3
            )
        )
        try await supervisor.start()

        do {
            let wavURL = URL(fileURLWithPath: wavPath)
            let inference = try await supervisor.transcribe(
                .init(
                    source: .microphone,
                    sequence: 0,
                    startMilliseconds: 0,
                    endMilliseconds: 5_000,
                    url: wavURL
                )
            )
            #expect(inference.source == .microphone)
            #expect(!inference.language.isEmpty)
            #expect(!inference.text.isEmpty)
            #expect(!inference.segments.isEmpty)
            #expect((await supervisor.snapshot()).resolvedLanguage == inference.language)
            await supervisor.stop()
            #expect((await supervisor.snapshot()).state == .stopped)
        } catch {
            await supervisor.stop()
            throw error
        }
    }

    private func waitForFailure(
        _ supervisor: WhisperServerSupervisor
    ) async -> WhisperServerSupervisor.Snapshot {
        for _ in 0..<50 {
            let snapshot = await supervisor.snapshot()
            if isFailed(snapshot.state) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("supervisor did not enter failed state")
        return await supervisor.snapshot()
    }

    private func isFailed(_ state: WhisperServerSupervisor.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServerSupervisorTests-\(UUID().uuidString)")
    }
}

private final class SupervisorStateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [WhisperServerSupervisor.State] = []

    func record(_ state: WhisperServerSupervisor.State) {
        lock.lock()
        states.append(state)
        lock.unlock()
    }

    func contains(_ state: WhisperServerSupervisor.State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states.contains(state)
    }
}

struct FakeWhisperFixture {
    let root: URL
    let executableURL: URL
    let modelURL: URL

    init(modelName: String = "model.bin") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeWhisperServer-\(UUID().uuidString)")
        executableURL = root.appendingPathComponent("fake-whisper-server")
        modelURL = root.appendingPathComponent(modelName)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.serverScript.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        try Data("model".utf8).write(to: modelURL)
    }

    var configuration: WhisperServerSupervisor.Configuration {
        configuration()
    }

    func configuration(
        startupTimeout: TimeInterval = 2
    ) -> WhisperServerSupervisor.Configuration {
        .init(
            executableURL: executableURL,
            modelURL: modelURL,
            requestedLanguage: "auto",
            threads: 1,
            startupTimeout: startupTimeout,
            requestTimeout: 2,
            shutdownTimeout: 1,
            maxDiagnosticBytes: 4_096
        )
    }

    func request(
        named name: String,
        source: TranscriptionSource,
        sequence: Int
    ) -> TranscriptionChunkPipeline.Chunk {
        let url = root.appendingPathComponent(name)
        try? Data("RIFF-fake".utf8).write(to: url)
        return .init(
            source: source,
            sequence: sequence,
            startMilliseconds: Int64(sequence * 4_000),
            endMilliseconds: Int64(sequence * 4_000 + 5_000),
            url: url
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static let serverScript = """
    #!/usr/bin/python3
    import http.server
    import json
    import os
    import sys
    import threading
    import time

    def argument(name):
        index = sys.argv.index(name)
        return sys.argv[index + 1]

    host = argument("--host")
    port = int(argument("--port"))
    model = argument("--model")
    ready = "never-ready" not in model
    active = 0
    active_lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health" and ready:
                self.send_json(200, {"status": "ok"})
            else:
                self.send_json(503, {"status": "loading model"})

        def do_POST(self):
            global active
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            if b'filename="crash.wav"' in body:
                os._exit(7)
            if b'filename="silent.wav"' in body:
                self.send_json(200, {
                    "language": "english",
                    "duration": 1.0,
                    "text": "",
                    "segments": []
                })
                return
            with active_lock:
                active += 1
                observed_active = active
            time.sleep(0.15)
            with active_lock:
                active -= 1
            self.send_json(200, {
                "language": "italian",
                "duration": 1.0,
                "text": "active=" + str(observed_active),
                "segments": [{"start": 0.0, "end": 1.0, "text": " prova"}]
            })

    print("fake whisper-server ready", flush=True)
    http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()
    """
}
