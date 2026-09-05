import SwiftUI

// MARK: - RecordingControlsView
// Controls for starting/stopping recording and selecting audio sources.
//
// SwiftUI views are structs that describe UI. They're lightweight and
// frequently recreated - SwiftUI's diffing engine figures out what changed.

struct RecordingControlsView: View {

    // @Bindable creates a two-way connection to an @Observable object.
    // Changes to 'state' properties trigger view updates.
    // The $ prefix (e.g., $state.recordSystemAudio) creates a Binding for two-way data flow.
    @Bindable var state: RecordingState

    // Closure called when start/stop button is tapped.
    // @escaping means the closure might be stored and called later.
    let onStartStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {

            // MARK: Source Toggles
            // Checkboxes to select which audio sources to record.
            HStack(spacing: 16) {

                // System audio toggle
                // $state.recordSystemAudio is a Binding<Bool> - two-way data flow.
                // When the user toggles, it updates state.recordSystemAudio.
                Toggle(isOn: $state.recordSystemAudio) {
                    // Label combines an icon and text.
                    Label("System", systemImage: "speaker.wave.2")
                }
                .toggleStyle(.checkbox)  // macOS checkbox appearance
                .disabled(state.isRecording)  // Can't change while recording

                // Microphone toggle
                Toggle(isOn: $state.recordMicrophone) {
                    Label("Mic", systemImage: "mic")
                }
                .toggleStyle(.checkbox)
                .disabled(state.isRecording)
            }
            .font(.caption)

            // MARK: Recording Status
            // Only shown while recording.
            if state.isRecording {
                HStack {
                    if state.isStopping {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finalizing recording…")
                            .font(.caption)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .opacity(pulseOpacity)
                        Text(state.formatElapsedTime())
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }

            // MARK: Start/Stop Button
            Button(action: onStartStop) {
                HStack {
                    if state.isStopping {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finishing…")
                    } else {
                        Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                        Text(state.isRecording ? "Stop Recording" : "Start Recording")
                    }
                }
                .frame(maxWidth: .infinity)  // Fill available width
            }
            .buttonStyle(.borderedProminent)  // Filled, prominent button
            .tint(state.isRecording ? .red : .blue)  // Red when recording, blue otherwise
            .disabled(
                !canRecord
                    || state.isStopping
                    || (!state.isRecording && !state.canStartRecording)
            )
            .controlSize(.large)  // Bigger button

            // MARK: Output Path
            if let path = state.outputPath {
                CopyablePathRow(label: "Recording", url: path)
            }
        }
    }

    // MARK: - Computed Properties

    /// Can we start recording? At least one source must be selected.
    private var canRecord: Bool {
        return state.recordSystemAudio || state.recordMicrophone
    }

    // @State creates view-local mutable state.
    // SwiftUI manages this - it persists across view recreations.
    @State private var pulsePhase = false

    /// Opacity for the pulsing recording indicator.
    private var pulseOpacity: Double {
        pulsePhase ? 1.0 : 0.3
    }

    // MARK: - Initializer
    // Custom init to set up required properties.
    // 'state' is an @Observable object, 'onStartStop' is a closure.

    init(state: RecordingState, onStartStop: @escaping () -> Void) {
        self.state = state
        self.onStartStop = onStartStop
    }
}
