import AppKit
import SwiftUI

struct TranscriptionStatusView: View {
    @Bindable var state: RecordingState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Live transcription", isOn: $state.transcriptionEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(state.isRecording)

                Spacer()

                Button {
                    Task { await state.checkTranscriptionServer() }
                } label: {
                    if state.transcriptionDisplayState == .checking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Check", systemImage: "checkmark.circle")
                    }
                }
                .disabled(state.isRecording || state.transcriptionDisplayState == .checking)
                .help("Start whisper-server and verify its health endpoint")
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(serverTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Spoken language")
                    .font(.caption)
                    .fontWeight(.medium)
                Picker("Spoken language", selection: $state.transcriptionLanguage) {
                    Text("Italian").tag("it")
                    Text("English").tag("en")
                    Text("Automatic").tag("auto")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .disabled(state.isRecording)

            if let error = state.transcriptionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.transcriptionSnapshot.backlog > 0 || state.transcriptionSnapshot.lastCompletedSequence != nil {
                HStack(spacing: 12) {
                    Label(
                        "\(state.transcriptionSnapshot.backlog) pending",
                        systemImage: "tray.full"
                    )
                    if let sequence = state.transcriptionSnapshot.lastCompletedSequence {
                        Text("Last #\(sequence)")
                    }
                    if state.transcriptionSnapshot.lagMilliseconds > 0 {
                        Text("Lag \(formattedLag)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let transcriptURL = state.transcriptionSnapshot.transcriptURL {
                CopyablePathRow(label: "Transcript", url: transcriptURL)
            }
            if let bundleURL = state.transcriptionSnapshot.bundleURL {
                CopyablePathRow(label: "Session", url: bundleURL)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Server settings")
                    .font(.caption)
                    .fontWeight(.semibold)
                pathField("Executable", text: $state.whisperExecutablePath)
                pathField("Model", text: $state.whisperModelPath)
            }
            .font(.caption)
            .disabled(state.isRecording)
        }
    }

    private func pathField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 62, alignment: .leading)
            TextField("Not configured", text: text)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
        }
    }

    private var statusTitle: String {
        switch state.transcriptionDisplayState {
        case .disabled: return "Disabled"
        case .idle: return state.transcriptionEnabled ? "Not checked" : "Disabled"
        case .checking: return "Checking server…"
        case .ready: return state.transcriptionEnabled ? "Ready" : "Server ready"
        case .active: return "Transcribing"
        case .lagging: return "Transcribing — lagging"
        case .draining: return "Finishing transcript…"
        case .complete: return "Transcript complete"
        case .failed: return "Transcription failed"
        }
    }

    private var serverTitle: String {
        switch state.transcriptionSnapshot.serverState {
        case .idle: return "Server idle"
        case .starting: return "Server starting"
        case .ready: return "Server healthy"
        case .stopping: return "Server stopping"
        case .stopped: return "Server stopped"
        case .failed: return "Server failed"
        }
    }

    private var statusColor: Color {
        switch state.transcriptionDisplayState {
        case .ready, .active, .complete: return .green
        case .checking, .draining: return .blue
        case .lagging: return .orange
        case .failed: return .red
        case .disabled, .idle: return .secondary
        }
    }

    private var formattedLag: String {
        String(format: "%.1fs", Double(state.transcriptionSnapshot.lagMilliseconds) / 1_000)
    }
}

struct CopyablePathRow: View {
    let label: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(url.path)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url.path)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy path")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
    }
}
