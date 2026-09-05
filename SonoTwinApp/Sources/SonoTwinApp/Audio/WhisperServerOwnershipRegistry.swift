import Darwin
import Foundation

struct WhisperServerOwnershipRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let ownerProcessIdentifier: Int32
    let serverProcessIdentifier: Int32
    let token: String

    init(
        ownerProcessIdentifier: Int32,
        serverProcessIdentifier: Int32,
        token: String,
        schemaVersion: Int = WhisperServerOwnershipRecord.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.serverProcessIdentifier = serverProcessIdentifier
        self.token = token
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && ownerProcessIdentifier > 0
            && serverProcessIdentifier > 0
            && !token.isEmpty
    }
}

struct WhisperServerProcessAccess: Sendable {
    let currentProcessIdentifier: @Sendable () -> Int32
    let isRunning: @Sendable (Int32) -> Bool
    let hasEnvironmentEntry: @Sendable (Int32, String, String) -> Bool
    let sendSignal: @Sendable (Int32, Int32) -> Void

    static let live = WhisperServerProcessAccess(
        currentProcessIdentifier: { ProcessInfo.processInfo.processIdentifier },
        isRunning: { processIdentifier in
            guard processIdentifier > 0 else { return false }
            if Darwin.kill(processIdentifier, 0) == 0 {
                return true
            }
            return errno == EPERM
        },
        hasEnvironmentEntry: { processIdentifier, key, value in
            processContainsEnvironmentEntry(
                processIdentifier: processIdentifier,
                entry: "\(key)=\(value)"
            )
        },
        sendSignal: { processIdentifier, signal in
            _ = Darwin.kill(processIdentifier, signal)
        }
    )

    private static func processContainsEnvironmentEntry(
        processIdentifier: Int32,
        entry: String
    ) -> Bool {
        var arguments = [
            Int32(CTL_KERN),
            Int32(KERN_PROCARGS2),
            processIdentifier
        ]
        var byteCount = 0
        let sizeResult = arguments.withUnsafeMutableBufferPointer { buffer in
            sysctl(
                buffer.baseAddress,
                u_int(buffer.count),
                nil,
                &byteCount,
                nil,
                0
            )
        }
        guard sizeResult == 0, byteCount > 0 else { return false }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readResult = arguments.withUnsafeMutableBufferPointer { argumentsBuffer in
            bytes.withUnsafeMutableBytes { bytesBuffer in
                sysctl(
                    argumentsBuffer.baseAddress,
                    u_int(argumentsBuffer.count),
                    bytesBuffer.baseAddress,
                    &byteCount,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0 else { return false }

        let needle = Array(entry.utf8)
        let count = min(byteCount, bytes.count)
        guard !needle.isEmpty, count > needle.count else { return false }

        for start in 0...(count - needle.count - 1) {
            guard start == 0 || bytes[start - 1] == 0 else { continue }
            let end = start + needle.count
            guard bytes[end] == 0 else { continue }
            if bytes[start..<end].elementsEqual(needle) {
                return true
            }
        }
        return false
    }
}

actor WhisperServerOwnershipRegistry {
    static let environmentKey = "SONOTWIN_WHISPER_OWNER_TOKEN"
    static let shared = WhisperServerOwnershipRegistry(recordURL: defaultRecordURL)

    enum ReclaimResult: Equatable, Sendable {
        case none
        case removedStaleRecord
        case removedUnverifiableRecord
        case liveOwner(Int32)
        case terminated(Int32)
    }

    enum RegistryError: Error, Equatable, LocalizedError {
        case unableToTerminate(Int32)

        var errorDescription: String? {
            switch self {
            case .unableToTerminate(let processIdentifier):
                return "Unable to terminate orphaned whisper-server process \(processIdentifier)"
            }
        }
    }

    private static let defaultRecordURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("SonoTwin", isDirectory: true)
            .appendingPathComponent("whisper-server-owner.json")
    }()

    private let recordURL: URL
    private let processAccess: WhisperServerProcessAccess
    private let shutdownTimeout: TimeInterval
    private var reclaimTask: Task<ReclaimResult, Error>?

    init(
        recordURL: URL,
        processAccess: WhisperServerProcessAccess = .live,
        shutdownTimeout: TimeInterval = 3
    ) {
        self.recordURL = recordURL
        self.processAccess = processAccess
        self.shutdownTimeout = shutdownTimeout
    }

    func reclaimOrphanedServer() async throws -> ReclaimResult {
        if let reclaimTask {
            return try await reclaimTask.value
        }

        let recordURL = self.recordURL
        let processAccess = self.processAccess
        let shutdownTimeout = self.shutdownTimeout
        let task = Task {
            try await Self.performReclaim(
                recordURL: recordURL,
                processAccess: processAccess,
                shutdownTimeout: shutdownTimeout
            )
        }
        reclaimTask = task

        do {
            let result = try await task.value
            reclaimTask = nil
            return result
        } catch {
            reclaimTask = nil
            throw error
        }
    }

    func recordOwnership(serverProcessIdentifier: Int32, token: String) throws -> WhisperServerOwnershipRecord {
        let record = WhisperServerOwnershipRecord(
            ownerProcessIdentifier: processAccess.currentProcessIdentifier(),
            serverProcessIdentifier: serverProcessIdentifier,
            token: token
        )
        guard record.isValid else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let directoryURL = recordURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordURL.path
        )
        return record
    }

    func removeOwnership(_ record: WhisperServerOwnershipRecord) {
        Self.removeRecord(at: recordURL, matching: record)
    }

    private static func performReclaim(
        recordURL: URL,
        processAccess: WhisperServerProcessAccess,
        shutdownTimeout: TimeInterval
    ) async throws -> ReclaimResult {
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return .none
        }

        let record: WhisperServerOwnershipRecord
        do {
            let data = try Data(contentsOf: recordURL)
            record = try JSONDecoder().decode(WhisperServerOwnershipRecord.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: recordURL)
            return .removedUnverifiableRecord
        }

        guard record.isValid else {
            removeRecord(at: recordURL, matching: record)
            return .removedUnverifiableRecord
        }
        guard processAccess.isRunning(record.serverProcessIdentifier) else {
            removeRecord(at: recordURL, matching: record)
            return .removedStaleRecord
        }
        guard processAccess.hasEnvironmentEntry(
            record.serverProcessIdentifier,
            environmentKey,
            record.token
        ) else {
            removeRecord(at: recordURL, matching: record)
            return .removedUnverifiableRecord
        }
        guard !processAccess.isRunning(record.ownerProcessIdentifier) else {
            return .liveOwner(record.ownerProcessIdentifier)
        }

        processAccess.sendSignal(record.serverProcessIdentifier, SIGTERM)
        await waitForExit(
            record.serverProcessIdentifier,
            timeout: shutdownTimeout,
            processAccess: processAccess
        )
        if processAccess.isRunning(record.serverProcessIdentifier) {
            processAccess.sendSignal(record.serverProcessIdentifier, SIGKILL)
            await waitForExit(
                record.serverProcessIdentifier,
                timeout: 1,
                processAccess: processAccess
            )
        }
        guard !processAccess.isRunning(record.serverProcessIdentifier) else {
            throw RegistryError.unableToTerminate(record.serverProcessIdentifier)
        }

        removeRecord(at: recordURL, matching: record)
        return .terminated(record.serverProcessIdentifier)
    }

    private static func waitForExit(
        _ processIdentifier: Int32,
        timeout: TimeInterval,
        processAccess: WhisperServerProcessAccess
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while processAccess.isRunning(processIdentifier), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func removeRecord(
        at recordURL: URL,
        matching expectedRecord: WhisperServerOwnershipRecord
    ) {
        guard let data = try? Data(contentsOf: recordURL),
              let currentRecord = try? JSONDecoder().decode(
                WhisperServerOwnershipRecord.self,
                from: data
              ),
              currentRecord == expectedRecord else {
            return
        }
        try? FileManager.default.removeItem(at: recordURL)
    }
}
