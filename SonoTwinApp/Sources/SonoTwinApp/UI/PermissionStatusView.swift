import SwiftUI

// MARK: - PermissionStatusView
// Shows the status of microphone and screen recording permissions.
// Each permission shows as a colored dot with optional action button.
//
// @Bindable is used with @Observable classes to create two-way bindings.
// Changes to permissionManager are automatically reflected in the UI.

struct PermissionStatusView: View {

    // @Bindable creates a binding to an @Observable object.
    // This allows the view to both read and trigger updates.
    @Bindable var permissionManager: PermissionManager

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                PermissionIndicator(
                    label: "Microphone",
                    state: permissionManager.microphonePermission,
                    onRequest: {
                        Task {
                            await permissionManager.requestMicrophonePermission()
                        }
                    },
                    onOpenSettings: {
                        permissionManager.openSystemSettings(for: "microphone")
                    }
                )

                PermissionIndicator(
                    label: "System Recording",
                    state: permissionManager.screenRecordingPermission,
                    onRequest: {
                        Task {
                            await permissionManager.requestScreenRecordingPermission()
                        }
                    },
                    onOpenSettings: {
                        permissionManager.openSystemSettings(for: "screenRecording")
                    }
                )
            }

            if permissionManager.screenRecordingPermission == .denied {
                HStack(spacing: 6) {
                    Text("Already enabled? Recheck, then quit and reopen SonoTwin if macOS still reports it disabled.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if permissionManager.isRefreshingScreenRecording {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Recheck") {
                            Task {
                                await permissionManager.refreshPermissions()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
                .help(permissionManager.screenRecordingDiagnostic ?? "")
            }
        }
    }
}

// MARK: - PermissionIndicator
// A single permission status indicator with colored dot and action button.
// This is a separate view to encapsulate the logic for one permission.

struct PermissionIndicator: View {

    let label: String
    let state: PermissionManager.PermissionState  // The current permission state

    // Closures for actions - these are called when buttons are tapped.
    // () -> Void means "a function taking no arguments and returning nothing".
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {

            // Status dot and label
            HStack(spacing: 4) {
                // Colored circle indicating permission state
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)

                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Action button (shown only for certain states)
            if state == .notDetermined {
                // User hasn't been asked yet - show "Grant" button
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.link)  // Looks like a hyperlink
                .font(.caption2)

            } else if state == .denied {
                // User denied - show "Settings" button to open System Settings
                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            // No button shown for .authorized or .unknown states
        }
    }

    // MARK: - Computed Property for State Color
    // Computed properties calculate their value each time they're accessed.
    // This is cleaner than a function when the result depends only on stored properties.

    private var stateColor: Color {
        switch state {
        case .authorized:
            return .green   // Permission granted
        case .denied:
            return .red     // Permission denied
        case .notDetermined:
            return .yellow  // Not yet asked
        case .unknown:
            return .gray    // Unknown state
        }
    }
}
