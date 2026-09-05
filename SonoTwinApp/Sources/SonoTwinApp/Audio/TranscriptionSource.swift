import Foundation

/// Capture stream identity preserved through chunking and transcription.
enum TranscriptionSource: String, CaseIterable, Codable, Hashable, Sendable {
    case microphone
    case system
}
