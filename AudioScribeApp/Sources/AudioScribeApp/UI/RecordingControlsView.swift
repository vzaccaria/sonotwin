import SwiftUI

/// Recording controls (start/stop, source toggles, duration)
struct RecordingControlsView: View {
    @Bindable var state: RecordingState
    let onStartStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Source toggles
            HStack(spacing: 16) {
                Toggle(isOn: $state.recordSystemAudio) {
                    Label("System", systemImage: "speaker.wave.2")
                }
                .toggleStyle(.checkbox)
                .disabled(state.isRecording)

                Toggle(isOn: $state.recordMicrophone) {
                    Label("Mic", systemImage: "mic")
                }
                .toggleStyle(.checkbox)
                .disabled(state.isRecording)
            }
            .font(.caption)

            // Recording status and timer
            if state.isRecording {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulseOpacity)

                    Text(state.formatElapsedTime())
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }

            // Start/Stop button
            Button(action: onStartStop) {
                HStack {
                    Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    Text(state.isRecording ? "Stop Recording" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isRecording ? .red : .blue)
            .disabled(!canRecord)
            .controlSize(.large)

            // Output path display
            if state.isRecording, let path = state.outputPath {
                Text(path.lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var canRecord: Bool {
        return state.recordSystemAudio || state.recordMicrophone
    }

    @State private var pulsePhase = false

    private var pulseOpacity: Double {
        pulsePhase ? 1.0 : 0.3
    }

    init(state: RecordingState, onStartStop: @escaping () -> Void) {
        self.state = state
        self.onStartStop = onStartStop
    }
}
