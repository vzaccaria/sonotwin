import Foundation

actor TranscriptSessionStore {
    enum Lifecycle: String, Codable, Sendable {
        case preparing
        case active
        case draining
        case complete
        case incomplete
        case failed
    }

    enum RecoveryError: Error, Equatable, LocalizedError {
        case missingManifest(String)
        case invalidChunkName(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest(let path):
                return "Transcript recovery manifest is missing at \(path)"
            case .invalidChunkName(let path):
                return "Transcript recovery chunk has an invalid name at \(path)"
            }
        }
    }

    struct Configuration: Sendable {
        let bundleURL: URL
        let recordingURL: URL
        let executableURL: URL
        let modelURL: URL
        let requestedLanguage: String
        let cadenceMilliseconds: Int64
        let overlapMilliseconds: Int64
        let keepChunks: Bool

        init(
            bundleURL: URL,
            recordingURL: URL,
            executableURL: URL,
            modelURL: URL,
            requestedLanguage: String,
            cadenceMilliseconds: Int64 = 5_000,
            overlapMilliseconds: Int64 = 1_000,
            keepChunks: Bool = false
        ) {
            self.bundleURL = bundleURL
            self.recordingURL = recordingURL
            self.executableURL = executableURL
            self.modelURL = modelURL
            self.requestedLanguage = requestedLanguage
            self.cadenceMilliseconds = cadenceMilliseconds
            self.overlapMilliseconds = overlapMilliseconds
            self.keepChunks = keepChunks
        }
    }

    struct Record: Codable, Equatable, Sendable {
        let v: Int
        let sessionId: String
        let seq: Int
        let chunkSeq: Int
        let source: TranscriptionSource
        let startMs: Int64
        let endMs: Int64
        let language: String
        let text: String
        let final: Bool
        let committedAt: String
    }

    struct Snapshot: Equatable, Sendable {
        let lifecycle: Lifecycle
        let transcriptURL: URL
        let jsonlURL: URL
        let bundleURL: URL
        let lastSequence: Int?
        let producedChunkCount: Int
        let transcribedChunkCount: Int
        let lagMilliseconds: Int64
        let error: String?
    }

    private struct AudioFormat: Codable {
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let sessionId: String
        let recordingPath: String
        let createdAt: String
        let audioFormat: AudioFormat
        let cadenceMs: Int64
        let overlapMs: Int64
        let backend: String
        let executablePath: String
        let modelPath: String
        let requestedLanguage: String
        var detectedLanguage: String?
        var lifecycle: Lifecycle
        var producedChunks: [String: Int]
        var transcribedChunks: [String: Int]
        var producedEndMilliseconds: [String: Int64]?
        var transcribedEndMilliseconds: [String: Int64]?
        var lastSequence: Int?
        var error: String?
    }

    private struct CandidateSegment {
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let text: String
    }

    let bundleURL: URL
    let transcriptURL: URL
    let jsonlURL: URL
    let chunksURL: URL

    private let manifestURL: URL
    private let manifestPartURL: URL
    private let configuration: Configuration
    private let jsonlHandle: FileHandle
    private let transcriptHandle: FileHandle
    private var manifest: Manifest
    private var nextSequence: Int
    private var committedHorizons: [TranscriptionSource: Int64]
    private var recentText: [TranscriptionSource: String]

    static func reopen(bundleURL: URL) throws -> TranscriptSessionStore {
        let manifestURL = bundleURL.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RecoveryError.missingManifest(manifestURL.path)
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        return try TranscriptSessionStore(
            configuration: .init(
                bundleURL: bundleURL,
                recordingURL: URL(fileURLWithPath: manifest.recordingPath),
                executableURL: URL(fileURLWithPath: manifest.executablePath),
                modelURL: URL(fileURLWithPath: manifest.modelPath),
                requestedLanguage: manifest.requestedLanguage,
                cadenceMilliseconds: manifest.cadenceMs,
                overlapMilliseconds: manifest.overlapMs
            )
        )
    }

    init(configuration: Configuration) throws {
        self.configuration = configuration
        self.bundleURL = configuration.bundleURL
        self.transcriptURL = configuration.bundleURL.appendingPathComponent("transcript.txt")
        self.jsonlURL = configuration.bundleURL.appendingPathComponent("transcript.jsonl")
        self.chunksURL = configuration.bundleURL.appendingPathComponent("chunks", isDirectory: true)
        self.manifestURL = configuration.bundleURL.appendingPathComponent("session.json")
        self.manifestPartURL = configuration.bundleURL.appendingPathComponent("session.json.part")

        try FileManager.default.createDirectory(
            at: configuration.bundleURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        try Self.removeStalePartFiles(under: chunksURL)

        let decoder = JSONDecoder()
        let existingManifest: Manifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            existingManifest = try decoder.decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } else {
            existingManifest = nil
        }

        let sessionId = existingManifest?.sessionId ?? UUID().uuidString
        let recoveredRecords = try Self.loadCompleteRecords(
            from: jsonlURL,
            sessionId: sessionId
        )
        self.nextSequence = (recoveredRecords.last?.seq ?? -1) + 1
        self.committedHorizons = Dictionary(
            grouping: recoveredRecords,
            by: \Record.source
        ).mapValues { records in records.map(\.endMs).max() ?? 0 }
        self.recentText = Dictionary(
            grouping: recoveredRecords,
            by: \Record.source
        ).compactMapValues { records in
            records.suffix(4).map(\.text).joined(separator: " ")
        }

        if let existingManifest {
            self.manifest = existingManifest
        } else {
            self.manifest = Manifest(
                schemaVersion: 1,
                sessionId: sessionId,
                recordingPath: configuration.recordingURL.path,
                createdAt: Self.timestamp(),
                audioFormat: AudioFormat(sampleRate: 48_000, channels: 2, bitsPerSample: 16),
                cadenceMs: configuration.cadenceMilliseconds,
                overlapMs: configuration.overlapMilliseconds,
                backend: "whisper.cpp/whisper-server",
                executablePath: configuration.executableURL.path,
                modelPath: configuration.modelURL.path,
                requestedLanguage: configuration.requestedLanguage,
                detectedLanguage: nil,
                lifecycle: .preparing,
                producedChunks: [:],
                transcribedChunks: [:],
                producedEndMilliseconds: [:],
                transcribedEndMilliseconds: [:],
                lastSequence: recoveredRecords.last?.seq,
                error: nil
            )
        }

        try Self.rebuildTranscript(recoveredRecords, at: transcriptURL)
        if !FileManager.default.fileExists(atPath: jsonlURL.path) {
            _ = FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        }
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            _ = FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        }
        self.jsonlHandle = try FileHandle(forWritingTo: jsonlURL)
        self.transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        try self.jsonlHandle.seekToEnd()
        try self.transcriptHandle.seekToEnd()
        try Self.writeManifest(
            manifest,
            to: manifestURL,
            temporaryURL: manifestPartURL
        )
    }

    deinit {
        try? jsonlHandle.close()
        try? transcriptHandle.close()
    }

    func setLifecycle(_ lifecycle: Lifecycle, error: String? = nil) throws {
        manifest.lifecycle = lifecycle
        manifest.error = error
        try writeManifest()
    }

    func markProduced(_ chunk: TranscriptionChunkPipeline.Chunk) throws {
        let key = chunk.source.rawValue
        manifest.producedChunks[key] = max(manifest.producedChunks[key] ?? -1, chunk.sequence)
        var producedEnds = manifest.producedEndMilliseconds ?? [:]
        producedEnds[key] = max(producedEnds[key] ?? 0, chunk.endMilliseconds)
        manifest.producedEndMilliseconds = producedEnds
        try writeManifest()
    }

    func isTranscribed(_ chunk: TranscriptionChunkPipeline.Chunk) -> Bool {
        (manifest.transcribedChunks[chunk.source.rawValue] ?? -1) >= chunk.sequence
    }

    @discardableResult
    func append(_ inference: WhisperServerSupervisor.Inference) throws -> [Record] {
        let chunk = inference.chunk
        guard !isTranscribed(chunk) else { return [] }

        let candidates = candidateSegments(from: inference)
        var appended: [Record] = []
        var horizon = committedHorizons[chunk.source] ?? 0
        var previousText = recentText[chunk.source] ?? ""
        let committedAt = Self.timestamp()

        for candidate in candidates {
            guard candidate.endMilliseconds > horizon else { continue }

            var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var startMilliseconds = max(candidate.startMilliseconds, horizon)
            let withinOverlap = candidate.startMilliseconds
                < horizon + configuration.overlapMilliseconds
            if withinOverlap {
                text = Self.removingRepeatedPrefix(text, after: previousText)
            }

            horizon = max(horizon, candidate.endMilliseconds)
            guard !text.isEmpty else { continue }
            if startMilliseconds >= candidate.endMilliseconds {
                startMilliseconds = max(0, candidate.endMilliseconds - 1)
            }

            let record = Record(
                v: 1,
                sessionId: manifest.sessionId,
                seq: nextSequence,
                chunkSeq: chunk.sequence,
                source: chunk.source,
                startMs: startMilliseconds,
                endMs: candidate.endMilliseconds,
                language: inference.language,
                text: text,
                final: true,
                committedAt: committedAt
            )
            nextSequence += 1
            appended.append(record)
            previousText = Self.recentText(previousText, appending: text)
        }

        if !appended.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var jsonlData = Data()
            var transcriptData = Data()
            for record in appended {
                jsonlData.append(try encoder.encode(record))
                jsonlData.append(0x0A)
                transcriptData.append(Data(Self.transcriptLine(for: record).utf8))
            }
            try jsonlHandle.write(contentsOf: jsonlData)
            try jsonlHandle.synchronize()
            try transcriptHandle.write(contentsOf: transcriptData)
            try transcriptHandle.synchronize()
        }

        committedHorizons[chunk.source] = horizon
        recentText[chunk.source] = previousText
        manifest.transcribedChunks[chunk.source.rawValue] = chunk.sequence
        var transcribedEnds = manifest.transcribedEndMilliseconds ?? [:]
        transcribedEnds[chunk.source.rawValue] = max(
            transcribedEnds[chunk.source.rawValue] ?? 0,
            chunk.endMilliseconds
        )
        manifest.transcribedEndMilliseconds = transcribedEnds
        manifest.lastSequence = appended.last?.seq ?? manifest.lastSequence
        if manifest.detectedLanguage == nil, !inference.text.isEmpty {
            manifest.detectedLanguage = inference.language
        }
        try writeManifest()
        return appended
    }

    func snapshot() -> Snapshot {
        let produced = manifest.producedChunks.values.reduce(0) { $0 + $1 + 1 }
        let transcribed = manifest.transcribedChunks.values.reduce(0) { $0 + $1 + 1 }
        let producedEnds = manifest.producedEndMilliseconds ?? [:]
        let transcribedEnds = manifest.transcribedEndMilliseconds ?? [:]
        let lag = producedEnds.reduce(Int64(0)) { current, entry in
            max(current, entry.value - (transcribedEnds[entry.key] ?? 0))
        }

        return Snapshot(
            lifecycle: manifest.lifecycle,
            transcriptURL: transcriptURL,
            jsonlURL: jsonlURL,
            bundleURL: bundleURL,
            lastSequence: manifest.lastSequence,
            producedChunkCount: produced,
            transcribedChunkCount: transcribed,
            lagMilliseconds: max(0, lag),
            error: manifest.error
        )
    }

    func pendingChunks() throws -> [TranscriptionChunkPipeline.Chunk] {
        var pending: [TranscriptionChunkPipeline.Chunk] = []
        for source in TranscriptionSource.allCases {
            let sourceURL = chunksURL.appendingPathComponent(
                source.rawValue,
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                continue
            }
            let chunkURLs = try FileManager.default.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for chunkURL in chunkURLs
            where chunkURL.pathExtension.lowercased() == "wav" {
                let fields = chunkURL.deletingPathExtension().lastPathComponent
                    .split(separator: "_", omittingEmptySubsequences: false)
                guard fields.count == 3,
                      let sequence = Int(fields[0]),
                      let startMilliseconds = Int64(fields[1]),
                      let endMilliseconds = Int64(fields[2]),
                      sequence >= 0,
                      startMilliseconds >= 0,
                      endMilliseconds > startMilliseconds else {
                    throw RecoveryError.invalidChunkName(chunkURL.path)
                }
                let chunk = TranscriptionChunkPipeline.Chunk(
                    source: source,
                    sequence: sequence,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds,
                    url: chunkURL
                )
                if !isTranscribed(chunk) {
                    pending.append(chunk)
                }
            }
        }
        return pending.sorted { lhs, rhs in
            if lhs.endMilliseconds != rhs.endMilliseconds {
                return lhs.endMilliseconds < rhs.endMilliseconds
            }
            if lhs.startMilliseconds != rhs.startMilliseconds {
                return lhs.startMilliseconds < rhs.startMilliseconds
            }
            if lhs.source != rhs.source {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.sequence < rhs.sequence
        }
    }

    func removeChunksAfterCompletion() throws {
        guard !configuration.keepChunks, manifest.lifecycle == .complete else { return }
        if FileManager.default.fileExists(atPath: chunksURL.path) {
            try FileManager.default.removeItem(at: chunksURL)
        }
    }

    private func candidateSegments(
        from inference: WhisperServerSupervisor.Inference
    ) -> [CandidateSegment] {
        if inference.segments.isEmpty {
            let text = inference.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                CandidateSegment(
                    startMilliseconds: inference.chunk.startMilliseconds,
                    endMilliseconds: inference.chunk.endMilliseconds,
                    text: text
                )
            ]
        }

        return inference.segments.compactMap { segment in
            let start = inference.chunk.startMilliseconds
                + Int64((segment.startSeconds * 1_000).rounded())
            let end = inference.chunk.startMilliseconds
                + Int64((segment.endSeconds * 1_000).rounded())
            let clampedStart = max(inference.chunk.startMilliseconds, start)
            let clampedEnd = min(inference.chunk.endMilliseconds, end)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clampedEnd > clampedStart, !text.isEmpty else { return nil }
            return CandidateSegment(
                startMilliseconds: clampedStart,
                endMilliseconds: clampedEnd,
                text: text
            )
        }
    }

    private func writeManifest() throws {
        try Self.writeManifest(
            manifest,
            to: manifestURL,
            temporaryURL: manifestPartURL
        )
    }

    private static func writeManifest(
        _ manifest: Manifest,
        to url: URL,
        temporaryURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        try atomicWrite(data, to: url, temporaryURL: temporaryURL)
    }

    private static func loadCompleteRecords(from url: URL, sessionId: String) throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let finalNewline = data.lastIndex(of: 0x0A) else {
            try Data().write(to: url)
            return []
        }

        let completeData = Data(data[...finalNewline])
        if completeData.count != data.count {
            try completeData.write(to: url)
        }

        let decoder = JSONDecoder()
        return try completeData.split(separator: 0x0A).compactMap { line in
            let record = try decoder.decode(Record.self, from: Data(line))
            guard record.v == 1, record.sessionId == sessionId, record.final,
                  record.endMs > record.startMs, !record.text.isEmpty else {
                return nil
            }
            return record
        }
    }

    private static func rebuildTranscript(_ records: [Record], at url: URL) throws {
        var data = Data()
        for record in records {
            data.append(Data(transcriptLine(for: record).utf8))
        }
        let temporaryURL = url.appendingPathExtension("part")
        try atomicWrite(data, to: url, temporaryURL: temporaryURL)
    }

    private static func transcriptLine(for record: Record) -> String {
        "[\(clock(record.startMs))–\(clock(record.endMs))] [\(record.source.rawValue)] \(record.text)\n"
    }

    private static func clock(_ milliseconds: Int64) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let millis = milliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
    }

    private static func removingRepeatedPrefix(_ candidate: String, after previous: String) -> String {
        let candidateWords = candidate.split(whereSeparator: \Character.isWhitespace).map(String.init)
        let previousWords = previous.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !candidateWords.isEmpty, !previousWords.isEmpty else { return candidate }

        let normalizedCandidate = candidateWords.map(normalizedWord)
        let normalizedPrevious = previousWords.map(normalizedWord)
        let maximum = min(normalizedCandidate.count, normalizedPrevious.count)
        var overlap = 0
        for count in stride(from: maximum, through: 1, by: -1) {
            if normalizedPrevious.suffix(count).elementsEqual(normalizedCandidate.prefix(count)) {
                overlap = count
                break
            }
        }
        return candidateWords.dropFirst(overlap).joined(separator: " ")
    }

    private static func normalizedWord(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func recentText(_ previous: String, appending text: String) -> String {
        let words = (previous + " " + text).split(whereSeparator: \Character.isWhitespace)
        return words.suffix(32).joined(separator: " ")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func removeStalePartFiles(under directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "part" {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL, temporaryURL: URL) throws {
        try? FileManager.default.removeItem(at: temporaryURL)
        _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
