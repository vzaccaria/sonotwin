import SwiftUI

// MARK: - PopoverContentView
// The main content view displayed in the menu bar popover.
// This is a "container view" that assembles other views into a complete UI.
//
// SwiftUI uses a declarative syntax - you describe what the UI should look like,
// and SwiftUI handles creating, updating, and animating the actual views.

struct PopoverContentView: View {

    // @Bindable connects to an @Observable object.
    // When any @Observable property changes, SwiftUI re-evaluates body.
    @Bindable var state: RecordingState

    var body: some View {
        // VStack stacks children vertically.
        // spacing: 16 puts 16 points between each child.
        VStack(spacing: 16) {

            // MARK: Header
            HStack {
                // SF Symbol icon - Apple's built-in icon library
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                Text("SonoTwin")
                    .font(.headline)
                Spacer()  // Pushes content to the left
            }

            Divider()  // Horizontal line separator

            // MARK: Permission Status
            // Shows mic and screen recording permission states.
            // state.permissionManager is also @Observable, so permission
            // changes automatically update this view.
            PermissionStatusView(permissionManager: state.permissionManager)

            Divider()

            // MARK: VU Meters
            // Real-time audio level meters.
            // These update ~30 times per second during recording.
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

            // MARK: Recording Controls
            // Start/stop button and source toggles.
            // The closure is called when the button is tapped.
            RecordingControlsView(state: state) {
                // Task creates an async context for await calls.
                Task {
                    if state.isRecording {
                        await state.stopRecording()
                    } else {
                        do {
                            try await state.startRecording()
                        } catch {
                            // In production, you'd show an error alert here.
                            print("Recording error: \(error)")
                        }
                    }
                }
            }

            Divider()

            // MARK: Footer
            HStack {
                // Quit button terminates the app.
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)  // Looks like a hyperlink
                .font(.caption)

                Spacer()

                // Version number
                Text("v1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()  // Add padding around all edges
        .frame(width: 280)  // Fixed width for the popover
    }
}
