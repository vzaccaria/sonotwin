import SwiftUI

/// Main popover content view
struct PopoverContentView: View {
    @Bindable var state: RecordingState

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                Text("AudioScribe")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Permission status
            PermissionStatusView(permissionManager: state.permissionManager)

            Divider()

            // VU Meters
            VStack(spacing: 12) {
                VUMeterView(
                    level: state.systemAudioLevel,
                    peak: state.systemAudioPeak,
                    label: "System Audio",
                    isEnabled: state.recordSystemAudio
                )

                VUMeterView(
                    level: state.microphoneLevel,
                    peak: state.microphonePeak,
                    label: "Microphone",
                    isEnabled: state.recordMicrophone
                )
            }

            Divider()

            // Recording controls
            RecordingControlsView(state: state) {
                Task {
                    if state.isRecording {
                        await state.stopRecording()
                    } else {
                        do {
                            try await state.startRecording()
                        } catch {
                            print("Recording error: \(error)")
                        }
                    }
                }
            }

            Divider()

            // Footer with quit button
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Text("v1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
